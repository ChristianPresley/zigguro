//! `ModelRegistry`: one table of models with limits, capabilities and
//! prices, merged from the embedded catalog, provider `list_models` and
//! user settings (`ai.models`), plus aliases and per-role profiles.
//!
//! Precedence: limits and capabilities user > API > catalog; price user >
//! catalog (APIs return no prices). Readers take an immutable snapshot
//! through an atomic pointer, so the read path takes no lock. Writers
//! rebuild a whole new snapshot; replaced snapshots are kept until
//! `deinit` because readers may still hold them (refreshes are rare).

const std = @import("std");
const proto = @import("zg_ai_proto");
const pricing = @import("pricing.zig");
const Capabilities = @import("../provider/capabilities.zig").Capabilities;
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const ContinueStrategy = @import("../provider/anthropic/recovery.zig").ContinueStrategy;

const Allocator = std.mem.Allocator;
const ProviderId = proto.ProviderId;

/// The built-in catalog source.
pub const builtin_catalog: [:0]const u8 = @embedFile("catalog.zon");

/// A capability flag by name (for ZON and settings).
pub const CapName = std.meta.FieldEnum(Capabilities);

pub const Lifecycle = enum { active, deprecated, retired };

/// Which layers contributed to a merged entry.
pub const Source = packed struct(u8) {
    catalog: bool = false,
    api: bool = false,
    user: bool = false,
    _pad: u5 = 0,
};

/// A merged model entry.
pub const ModelInfo = struct {
    id: []const u8,
    provider: ProviderId,
    display: []const u8,
    /// Token estimator calibration key.
    family: []const u8,
    context_window: u32,
    max_output: u32,
    caps: Capabilities,
    cache_min_tokens: u32 = 1024,
    price: ?pricing.Price = null,
    continue_strategy: ContinueStrategy = .user_continue_message,
    lifecycle: Lifecycle = .active,
    /// Unix seconds when the provider retires the model.
    retires_at: ?i64 = null,
    source: Source = .{},
};

/// Capability presets the catalog builds on.
pub const CapBase = enum { none, claude };

/// One `catalog.zon` model.
pub const CatalogEntry = struct {
    id: []const u8,
    provider: ProviderId = .anthropic,
    display: []const u8 = "",
    family: []const u8 = "",
    context_window: u32,
    max_output: u32,
    base: CapBase = .none,
    add: []const CapName = &.{},
    remove: []const CapName = &.{},
    cache_min_tokens: u32 = 1024,
    price: ?pricing.Price = null,
    continue_strategy: ContinueStrategy = .user_continue_message,
    lifecycle: Lifecycle = .active,
    aliases: []const []const u8 = &.{},

    pub fn capabilities(e: CatalogEntry) Capabilities {
        var c: Capabilities = switch (e.base) {
            .none => .{},
            .claude => @import("../provider/anthropic/Anthropic.zig").default_caps,
        };
        for (e.add) |n| setCap(&c, n, true);
        for (e.remove) |n| setCap(&c, n, false);
        return c;
    }
};

/// The `catalog.zon` document.
pub const Catalog = struct {
    retrieved: []const u8,
    models: []const CatalogEntry,
};

/// Sets one capability flag by name.
pub fn setCap(c: *Capabilities, n: CapName, v: bool) void {
    switch (n) {
        inline else => |tag| if (comptime @FieldType(Capabilities, @tagName(tag)) == bool) {
            @field(c, @tagName(tag)) = v;
        },
    }
}

/// Who a request is for; selects the profile and (for cheap roles) the model.
pub const Role = enum { main, subagent, compaction, title, assist };

/// Request knobs for a model in a role.
pub const Profile = struct {
    thinking: request.Thinking = .off,
    effort: ?request.Effort = null,
    max_output: ?u32 = null,
    temperature: ?f32 = null,
};

pub const RoleProfile = struct { role: Role, profile: Profile };

/// One entry of the `ai.models` setting.
pub const UserModel = struct {
    id: []const u8,
    provider: ?ProviderId = null,
    display: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output: ?u32 = null,
    caps: ?Capabilities = null,
    price: ?pricing.Price = null,
    profiles: []const RoleProfile = &.{},
};

/// An `ai.aliases` entry.
pub const Alias = struct { name: []const u8, target: []const u8 };

/// Notified after every snapshot swap (the UI posts to its thread).
pub const Listener = struct {
    ctx: *anyopaque,
    models_changed: *const fn (ctx: *anyopaque, s: *const Snapshot) void,
};

/// An immutable view of the merged table.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    version: u64,
    models: []const ModelInfo,
    by_id: std.StringHashMapUnmanaged(u32) = .empty,
    aliases: std.StringHashMapUnmanaged(u32) = .empty,
    /// "id\x00role" → profile, from user settings.
    profiles: std.StringHashMapUnmanaged(Profile) = .empty,

    /// Finds a model by id, alias or `provider/id`.
    pub fn resolve(s: *const Snapshot, name: []const u8) ?*const ModelInfo {
        if (s.by_id.get(name)) |i| return &s.models[i];
        if (s.aliases.get(name)) |i| return &s.models[i];
        if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
            const pid = std.meta.stringToEnum(ProviderId, name[0..slash]) orelse return null;
            for (s.models) |*m| if (m.provider == pid and std.mem.eql(u8, m.id, name[slash + 1 ..])) return m;
        }
        return null;
    }

    /// The cheapest active tool-capable model of `provider` (by output price).
    pub fn cheapest(s: *const Snapshot, provider: ?ProviderId) ?*const ModelInfo {
        var best: ?*const ModelInfo = null;
        for (s.models) |*m| {
            if (!m.caps.tools or m.lifecycle != .active) continue;
            if (provider) |p| if (m.provider != p) continue;
            const p = m.price orelse continue;
            if (best == null or p.output_per_mtok_micros < best.?.price.?.output_per_mtok_micros) best = m;
        }
        return best;
    }
};

const ApiLayer = struct {
    arena: std.heap.ArenaAllocator,
    provider: ProviderId,
    caps: Capabilities,
    models: []const Provider.ModelInfo,
};

pub const ModelRegistry = struct {
    gpa: Allocator,
    io: std.Io,
    catalog_src: [:0]const u8,
    mutex: std.Io.Mutex = .init,
    catalog_arena: std.heap.ArenaAllocator,
    catalog: ?Catalog = null,
    /// Times the catalog was parsed (0 until the first resolve).
    parse_count: u32 = 0,
    api: std.ArrayList(ApiLayer) = .empty,
    user_arena: std.heap.ArenaAllocator,
    user: []const UserModel = &.{},
    user_aliases: []const Alias = &.{},
    current: std.atomic.Value(?*Snapshot) = .init(null),
    retired: std.ArrayList(*Snapshot) = .empty,
    listeners: std.ArrayList(Listener) = .empty,
    version: u64 = 0,

    /// Does no parsing: the catalog is parsed on first use.
    pub fn init(gpa: Allocator, io: std.Io, catalog_src: [:0]const u8) ModelRegistry {
        return .{ .gpa = gpa, .io = io, .catalog_src = catalog_src, .catalog_arena = .init(gpa), .user_arena = .init(gpa) };
    }

    pub fn deinit(r: *ModelRegistry) void {
        if (r.current.load(.acquire)) |s| freeSnapshot(r.gpa, s);
        for (r.retired.items) |s| freeSnapshot(r.gpa, s);
        r.retired.deinit(r.gpa);
        for (r.api.items) |*l| l.arena.deinit();
        r.api.deinit(r.gpa);
        r.listeners.deinit(r.gpa);
        r.catalog_arena.deinit();
        r.user_arena.deinit();
    }

    /// The current snapshot (built on first call).
    pub fn snapshot(r: *ModelRegistry) error{ OutOfMemory, InvalidCatalog }!*const Snapshot {
        if (r.current.load(.acquire)) |s| return s;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.current.load(.acquire)) |s| return s;
        try r.rebuildLocked();
        return r.current.load(.acquire).?;
    }

    /// Finds a model by id, alias or `provider/id`.
    pub fn resolve(r: *ModelRegistry, name: []const u8) ?*const ModelInfo {
        const s = r.snapshot() catch return null;
        return s.resolve(name);
    }

    /// Replaces `provider`'s discovered models. API values win for limits.
    pub fn applyApi(r: *ModelRegistry, provider: ProviderId, caps: Capabilities, models: []const Provider.ModelInfo) error{ OutOfMemory, InvalidCatalog }!void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        var owned = true;
        errdefer if (owned) arena.deinit();
        const a = arena.allocator();
        const copy = try a.alloc(Provider.ModelInfo, models.len);
        for (models, copy) |m, *c| c.* = .{
            .id = try a.dupe(u8, m.id),
            .display_name = if (m.display_name) |d| try a.dupe(u8, d) else null,
            .context_window = m.context_window,
            .max_output = m.max_output,
            .created = m.created,
        };
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const layer: ApiLayer = .{ .arena = arena, .provider = provider, .caps = caps, .models = copy };
        owned = false;
        for (r.api.items) |*l| {
            if (l.provider != provider) continue;
            var old = l.arena;
            l.* = layer;
            old.deinit();
            break;
        } else r.api.append(r.gpa, layer) catch |e| {
            owned = true;
            return e;
        };
        try r.rebuildLocked();
    }

    /// Replaces the user layer (`ai.models` and `ai.aliases`).
    pub fn applyUser(r: *ModelRegistry, overrides: []const UserModel, aliases: []const Alias) error{ OutOfMemory, InvalidCatalog }!void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        var owned = true;
        errdefer if (owned) arena.deinit();
        const a = arena.allocator();
        const ms = try a.alloc(UserModel, overrides.len);
        for (overrides, ms) |o, *m| {
            m.* = o;
            m.id = try a.dupe(u8, o.id);
            if (o.display) |d| m.display = try a.dupe(u8, d);
            if (o.price) |p| m.price.?.tiers = try a.dupe(pricing.Tier, p.tiers);
            m.profiles = try a.dupe(RoleProfile, o.profiles);
        }
        const as = try a.alloc(Alias, aliases.len);
        for (aliases, as) |x, *y| y.* = .{ .name = try a.dupe(u8, x.name), .target = try a.dupe(u8, x.target) };
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.user_arena.deinit();
        r.user_arena = arena;
        owned = false;
        r.user = ms;
        r.user_aliases = as;
        try r.rebuildLocked();
    }

    /// Registers a `models_changed` listener.
    pub fn subscribe(r: *ModelRegistry, l: Listener) Allocator.Error!void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        try r.listeners.append(r.gpa, l);
    }

    /// The request knobs for `id` in `role`: user profile, else role defaults.
    pub fn profile(r: *ModelRegistry, id: []const u8, role: Role) Profile {
        const s = r.snapshot() catch return .{};
        const m = s.resolve(id) orelse return defaultProfile(null, role);
        var key_buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ m.id, @tagName(role) })) |key| {
            if (s.profiles.get(key)) |p| return p;
        } else |_| {}
        return defaultProfile(m, role);
    }

    /// The model for `role`: titles and compaction use the cheapest
    /// tool-capable model of the main model's provider when there is one.
    pub fn modelForRole(r: *ModelRegistry, main: *const ModelInfo, role: Role) *const ModelInfo {
        return switch (role) {
            .title, .compaction => blk: {
                const s = r.snapshot() catch break :blk main;
                break :blk s.cheapest(main.provider) orelse main;
            },
            else => main,
        };
    }

    fn ensureCatalog(r: *ModelRegistry) error{ OutOfMemory, InvalidCatalog }!Catalog {
        if (r.catalog) |c| return c;
        const c = std.zon.parse.fromSliceAlloc(Catalog, r.catalog_arena.allocator(), r.catalog_src, null, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => return error.InvalidCatalog,
        };
        r.parse_count += 1;
        r.catalog = c;
        return c;
    }

    fn rebuildLocked(r: *ModelRegistry) error{ OutOfMemory, InvalidCatalog }!void {
        const cat = try r.ensureCatalog();
        const s = try r.gpa.create(Snapshot);
        s.* = .{ .arena = .init(r.gpa), .version = r.version + 1, .models = &.{} };
        errdefer freeSnapshot(r.gpa, s);
        const a = s.arena.allocator();
        var list: std.ArrayList(ModelInfo) = .empty;

        for (cat.models) |e| try list.append(a, .{
            .id = e.id,
            .provider = e.provider,
            .display = if (e.display.len > 0) e.display else e.id,
            .family = if (e.family.len > 0) e.family else @tagName(e.provider),
            .context_window = e.context_window,
            .max_output = e.max_output,
            .caps = e.capabilities(),
            .cache_min_tokens = e.cache_min_tokens,
            .price = e.price,
            .continue_strategy = e.continue_strategy,
            .lifecycle = e.lifecycle,
            .source = .{ .catalog = true },
        });
        var local: ?usize = null;
        for (r.api.items) |l| for (l.models) |m| {
            const i = find(list.items, l.provider, m.id) orelse blk: {
                try list.append(a, .{
                    .id = try a.dupe(u8, m.id),
                    .provider = l.provider,
                    .display = try a.dupe(u8, m.display_name orelse m.id),
                    .family = @tagName(l.provider),
                    .context_window = 8192,
                    .max_output = 4096,
                    .caps = l.caps,
                });
                break :blk list.items.len - 1;
            };
            const x = &list.items[i];
            if (m.context_window) |v| x.context_window = v;
            if (m.max_output) |v| x.max_output = v;
            x.source.api = true;
            if (local == null and l.provider == .openai_chat) local = i;
        };
        for (r.user) |u| {
            const i = findUser(list.items, u) orelse blk: {
                try list.append(a, .{
                    .id = try a.dupe(u8, u.id),
                    .provider = u.provider orelse .unknown,
                    .display = u.id,
                    .family = if (u.provider) |p| @tagName(p) else "unknown",
                    .context_window = 8192,
                    .max_output = 4096,
                    .caps = .{},
                });
                break :blk list.items.len - 1;
            };
            const x = &list.items[i];
            if (u.display) |v| x.display = try a.dupe(u8, v);
            if (u.context_window) |v| x.context_window = v;
            if (u.max_output) |v| x.max_output = v;
            if (u.caps) |v| x.caps = v;
            if (u.price) |v| x.price = .{
                .input_per_mtok_micros = v.input_per_mtok_micros,
                .output_per_mtok_micros = v.output_per_mtok_micros,
                .cache_write_5m_mult_milli = v.cache_write_5m_mult_milli,
                .cache_write_1h_mult_milli = v.cache_write_1h_mult_milli,
                .cache_read_mult_milli = v.cache_read_mult_milli,
                .tiers = try a.dupe(pricing.Tier, v.tiers),
            };
            x.source.user = true;
            for (u.profiles) |rp| try s.profiles.put(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ x.id, @tagName(rp.role) }), rp.profile);
        }
        // Catalog strings stay in the catalog arena, which lives as long as
        // the registry.
        s.models = list.items;
        for (s.models, 0..) |m, i| try s.by_id.put(a, m.id, @intCast(i));

        for (cat.models) |e| for (e.aliases) |al| {
            if (s.by_id.get(e.id)) |i| try s.aliases.put(a, al, i);
        };
        if (s.cheapest(null)) |m| try s.aliases.put(a, "fast", s.by_id.get(m.id).?);
        if (local) |i| try s.aliases.put(a, "local", @intCast(i));
        for (r.user_aliases) |al| {
            const target = s.by_id.get(al.target) orelse s.aliases.get(al.target) orelse continue;
            try s.aliases.put(a, try a.dupe(u8, al.name), target);
        }

        r.version = s.version;
        if (r.current.swap(s, .acq_rel)) |old| r.retired.append(r.gpa, old) catch {
            // Can't free it safely; the arena leaks until process exit.
        };
        for (r.listeners.items) |l| l.models_changed(l.ctx, s);
    }
};

fn find(list: []const ModelInfo, provider: ProviderId, id: []const u8) ?usize {
    for (list, 0..) |m, i| if (m.provider == provider and std.mem.eql(u8, m.id, id)) return i;
    return null;
}

fn findUser(list: []const ModelInfo, u: UserModel) ?usize {
    for (list, 0..) |m, i| {
        if (u.provider) |p| if (m.provider != p) continue;
        if (std.mem.eql(u8, m.id, u.id)) return i;
    }
    return null;
}

fn freeSnapshot(gpa: Allocator, s: *Snapshot) void {
    s.arena.deinit();
    gpa.destroy(s);
}

/// Role defaults: the main agent thinks when the model can; helpers are cheap.
pub fn defaultProfile(m: ?*const ModelInfo, role: Role) Profile {
    const adaptive = if (m) |x| x.caps.thinking_adaptive else false;
    return switch (role) {
        .main => .{ .thinking = if (adaptive) .adaptive else .off },
        .subagent => .{ .thinking = if (adaptive) .adaptive else .off, .effort = .low },
        .compaction => .{ .effort = .low, .max_output = 8192 },
        .title => .{ .effort = .low, .max_output = 64 },
        .assist => .{ .effort = .low, .max_output = 1024 },
    };
}
