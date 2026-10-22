//! Catalogs (E11.F03.S01.T02): what a server offers (tools, resources,
//! resource templates, prompts), fetched whole, cached and kept current.
//!
//! **Pagination.** `walk` follows `nextCursor` until it is absent; an
//! empty-string cursor is a cursor, not the end. Page and entry caps
//! (`Options.max_pages`, `max_entries`) mark the catalog incomplete. An
//! invalid cursor (`-32602`) mid-walk drops the pages and restarts once.
//!
//! **Caching.** A catalog is fresh until the earliest page's
//! `t_received + ttlMs`. A negative or absent `ttlMs` is 0 on modern
//! servers. Legacy servers send no ttl: with `listChanged` the catalog
//! lasts until the server says it changed, otherwise for
//! `Options.heuristic_ttl_ms`. Pages fetched with MRTR input are never
//! cached. Stale catalogs are re-fetched lazily on `get`, never polled; a
//! failed re-fetch serves the old catalog marked stale. A `private`
//! catalog belongs to the auth context it was fetched under and is never
//! served to another.
//!
//! **Invalidation.** `*/list_changed` marks the catalog stale and refreshes
//! it after a 100 ms debounce, so a burst of notifications costs one walk.
//! A `HeaderMismatch`, an unknown-tool `-32602` or a reconnect invalidate
//! too. Listeners get the names added, removed and changed.
//!
//! **Reads are lock-free.** `acquire` loads the published pointer and
//! takes a reference; `release` drops it, and the last reference frees the
//! catalog. Between the load and the increment a publisher could drop the
//! store's own reference, so readers announce themselves in a counter
//! first, and `publish` waits for that counter to reach zero once after
//! the swap before dropping the old catalog's store reference (a grace
//! period of two atomic operations). A reader that got the pointer always
//! holds a reference before the catalog can be freed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const schema = @import("../schema/root.zig");
const hygiene = @import("tool_hygiene.zig");
const Client = @import("Client.zig");

const M = protocol.messages;
const Value = std.json.Value;

pub const ToolEntry = hygiene.ToolEntry;
pub const Excluded = hygiene.Excluded;

/// What a catalog lists.
pub const CatalogKind = enum {
    tools,
    resources,
    templates,
    prompts,

    /// The `*/list` method.
    pub fn method(k: CatalogKind) protocol.Method {
        return switch (k) {
            .tools => .tools_list,
            .resources => .resources_list,
            .templates => .resources_templates_list,
            .prompts => .prompts_list,
        };
    }

    /// The `notifications/*/list_changed` that invalidates `k`'s catalog
    /// (templates change with resources).
    pub fn fromListChanged(n: protocol.Notification) ?[]const CatalogKind {
        return switch (n) {
            .tools_list_changed => &.{.tools},
            .resources_list_changed => &.{ .resources, .templates },
            .prompts_list_changed => &.{.prompts},
            else => null,
        };
    }

    /// The `listChanged` server capability path.
    fn listChangedPath(k: CatalogKind) []const u8 {
        return switch (k) {
            .tools => "tools.listChanged",
            .resources, .templates => "resources.listChanged",
            .prompts => "prompts.listChanged",
        };
    }
};

/// The items of one page.
pub const Items = union(CatalogKind) {
    tools: []const M.Tool,
    resources: []const M.Resource,
    templates: []const M.ResourceTemplate,
    prompts: []const M.Prompt,

    fn len(i: Items) usize {
        return switch (i) {
            inline else => |s| s.len,
        };
    }
};

/// One page of a `*/list` result.
pub const Page = struct {
    items: Items,
    next_cursor: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    cache_scope: ?M.CacheScope = null,
    /// The request carried `inputResponses` / `requestState`: not cacheable.
    used_input: bool = false,
};

pub const FetchError = error{
    /// `-32602` for the cursor: restart the walk.
    InvalidCursor,
    OutOfMemory,
    /// Anything else (the transport's or server's error).
    Failed,
};

/// Fetches pages. `clientFetcher` is the real one; tests script their own.
pub const Fetcher = struct {
    ctx: ?*anyopaque,
    fetch: *const fn (ctx: ?*anyopaque, arena: Allocator, kind: CatalogKind, cursor: ?[]const u8) FetchError!Page,
};

/// A fetcher over a connected client.
pub const ClientFetcher = struct {
    client: *Client,

    pub fn fetcher(f: *ClientFetcher) Fetcher {
        return .{ .ctx = f, .fetch = fetch };
    }

    fn fetch(ctx: ?*anyopaque, arena: Allocator, kind: CatalogKind, cursor: ?[]const u8) FetchError!Page {
        const f: *ClientFetcher = @ptrCast(@alignCast(ctx.?));
        switch (kind) {
            inline else => |k| {
                var info: Client.ErrorInfo = .{};
                const r = f.client.request(comptime k.method(), .{ .cursor = cursor }, .{ .arena = arena, .error_info = &info }) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.ServerError => if (info.code == protocol.errors.invalid_params and cursor != null) error.InvalidCursor else error.Failed,
                    else => error.Failed,
                };
                const items: Items = switch (k) {
                    .tools => .{ .tools = r.tools },
                    .resources => .{ .resources = r.resources },
                    .templates => .{ .templates = r.resource_templates },
                    .prompts => .{ .prompts = r.prompts },
                };
                return .{ .items = items, .next_cursor = r.next_cursor, .ttl_ms = r.ttl_ms, .cache_scope = r.cache_scope };
            },
        }
    }
};

/// One published catalog. Immutable once published, except for lazily
/// compiled tool schemas (`inputSchema`).
pub const Catalog = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(1),
    kind: CatalogKind,
    /// Increases with every publish in a store.
    version: u64 = 0,
    /// When the first page arrived (ms since the epoch).
    fetched_at_ms: i64 = 0,
    /// Fresh until (ms); null: until invalidated.
    fresh_until_ms: ?i64 = null,
    scope: M.CacheScope = .public,
    /// The auth context a `private` catalog belongs to.
    auth_context: ?u64 = null,
    /// False when a page or entry cap cut the walk short.
    complete: bool = true,
    warnings: []const []const u8 = &.{},

    /// Kept tools, in server order (`tools`).
    entries: []ToolEntry = &.{},
    excluded: []const Excluded = &.{},
    resources: []const M.Resource = &.{},
    templates: []const M.ResourceTemplate = &.{},
    prompts: []const M.Prompt = &.{},

    /// Per item, in order: its key (name, or URI / URI template) and
    /// fingerprint. Used for `find` and change deltas.
    keys: []const []const u8 = &.{},
    prints: []const u64 = &.{},
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Serializes lazy schema compiles (they allocate from `arena`).
    compile_mutex: Io.Mutex = .init,

    pub const ToolCatalog = Catalog;

    fn create(gpa: Allocator, io: Io, kind: CatalogKind) Allocator.Error!*Catalog {
        const c = try gpa.create(Catalog);
        c.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .kind = kind };
        return c;
    }

    fn destroy(c: *Catalog) void {
        const gpa = c.gpa;
        c.arena.deinit();
        gpa.destroy(c);
    }

    /// Takes another reference.
    pub fn retain(c: *Catalog) void {
        _ = c.refs.fetchAdd(1, .monotonic);
    }

    /// Drops a reference; the last one frees the catalog.
    pub fn release(c: *Catalog) void {
        if (c.refs.fetchSub(1, .acq_rel) == 1) c.destroy();
    }

    /// Whether the catalog is fresh at `now_ms`.
    pub fn isFresh(c: *const Catalog, now_ms: i64) bool {
        const until = c.fresh_until_ms orelse return true;
        return now_ms < until;
    }

    /// The position of the item named `key` (O(1)).
    pub fn indexOf(c: *const Catalog, key: []const u8) ?u32 {
        return c.index.get(key);
    }

    /// The kept tool named `name`.
    pub fn find(c: *const Catalog, name: []const u8) ?*ToolEntry {
        if (c.kind != .tools) return null;
        const i = c.indexOf(name) orelse return null;
        return &c.entries[i];
    }

    /// Item positions sorted by key, for the UI (server order otherwise).
    pub fn sortedByName(c: *const Catalog, gpa: Allocator) Allocator.Error![]u32 {
        const out = try gpa.alloc(u32, c.keys.len);
        for (out, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, out, c.keys, struct {
            fn lt(keys: []const []const u8, a: u32, b: u32) bool {
                return std.mem.order(u8, keys[a], keys[b]) == .lt;
            }
        }.lt);
        return out;
    }

    /// `e`'s compiled input schema, compiling it on first use (snapshot
    /// catalogs); null when it does not compile.
    pub fn inputSchema(c: *Catalog, e: *ToolEntry) ?*const schema.Schema {
        return c.lazy(&e.input, e.def.input_schema);
    }

    /// `e`'s compiled output schema; null when absent or invalid.
    pub fn outputSchema(c: *Catalog, e: *ToolEntry) ?*const schema.Schema {
        return c.lazy(&e.output, e.def.output_schema orelse return null);
    }

    fn lazy(c: *Catalog, l: *hygiene.LazySchema, v: Value) ?*const schema.Schema {
        c.compile_mutex.lockUncancelable(c.io);
        defer c.compile_mutex.unlock(c.io);
        hygiene.compileInto(c.arena.allocator(), l, v);
        return if (l.state == .ready) l.compiled else null;
    }
};

pub const ToolCatalog = Catalog;

/// What changed between two catalogs of one kind.
pub const Delta = struct {
    kind: CatalogKind,
    added: []const []const u8,
    removed: []const []const u8,
    changed: []const []const u8,

    pub fn isEmpty(d: Delta) bool {
        return d.added.len == 0 and d.removed.len == 0 and d.changed.len == 0;
    }
};

/// Hears about published catalogs (F07's ToolBridge → E10).
pub const ChangeListener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, d: Delta, current: *Catalog) void,
};

pub const Options = struct {
    /// HTTP transport: `x-mcp-header` annotations are enforced.
    http: bool = false,
    /// Legacy era: no ttl on lists.
    legacy: bool = false,
    /// Per kind, whether the server declared `listChanged`.
    list_changed: std.EnumArray(CatalogKind, bool) = .initFill(false),
    /// Freshness for legacy servers without `listChanged`.
    heuristic_ttl_ms: u64 = 5 * 60 * 1000,
    max_pages: u32 = 1000,
    max_entries: u32 = 10_000,
    debounce: Io.Duration = .fromMilliseconds(100),

    /// The options matching a connected client.
    pub fn forClient(c: *const Client) Options {
        const info = c.serverInfo();
        var o: Options = .{
            .http = switch (c.owner) {
                .modern, .legacy, .sse => true,
                .stdio, .in_process => false,
            },
            .legacy = info.era == .legacy,
        };
        for (std.enums.values(CatalogKind)) |k| o.list_changed.set(k, info.capabilities.has(k.listChangedPath()));
        return o;
    }
};

/// The catalogs of one client.
pub const CatalogStore = struct {
    gpa: Allocator,
    io: Io,
    fetcher: Fetcher,
    opts: Options,
    slots: std.EnumArray(CatalogKind, Slot) = .initFill(.{}),
    /// Readers between loading a pointer and taking a reference.
    readers: std.atomic.Value(u32) = .init(0),
    /// 0: no auth context.
    auth_context: std.atomic.Value(u64) = .init(0),
    version: std.atomic.Value(u64) = .init(0),
    /// One walk at a time per store.
    refresh_mutex: Io.Mutex = .init,
    listeners_mutex: Io.Mutex = .init,
    listeners: std.ArrayList(ChangeListener) = .empty,
    tasks: Io.Group = .init,

    const Slot = struct {
        current: std.atomic.Value(?*Catalog) = .init(null),
        /// Set by invalidation; cleared by a publish.
        invalid: std.atomic.Value(bool) = .init(false),
        /// The last refresh failed; `current` is served stale.
        stale: std.atomic.Value(bool) = .init(false),
        /// A debounced refresh is scheduled.
        scheduled: std.atomic.Value(bool) = .init(false),
    };

    pub fn init(gpa: Allocator, io: Io, fetcher: Fetcher, opts: Options) CatalogStore {
        return .{ .gpa = gpa, .io = io, .fetcher = fetcher, .opts = opts };
    }

    /// Cancels pending refreshes and drops the store's references.
    pub fn deinit(s: *CatalogStore) void {
        s.tasks.cancel(s.io);
        for (std.enums.values(CatalogKind)) |k| if (s.slots.getPtr(k).current.swap(null, .acq_rel)) |c| c.release();
        s.listeners.deinit(s.gpa);
    }

    /// The published catalog of `kind`, whatever its freshness, with a
    /// reference the caller must `release`. Lock-free.
    pub fn acquire(s: *CatalogStore, kind: CatalogKind) ?*Catalog {
        _ = s.readers.fetchAdd(1, .acquire);
        defer _ = s.readers.fetchSub(1, .release);
        const c = s.slots.getPtr(kind).current.load(.acquire) orelse return null;
        c.retain();
        return c;
    }

    /// Whether the last refresh of `kind` failed (the catalog is stale).
    pub fn isStale(s: *CatalogStore, kind: CatalogKind) bool {
        return s.slots.getPtr(kind).stale.load(.acquire);
    }

    /// A usable catalog of `kind` (reference to `release`): the published
    /// one while fresh, otherwise a new walk. When the walk fails, the old
    /// catalog is returned and `isStale` says so; with none, the error.
    pub fn get(s: *CatalogStore, kind: CatalogKind) FetchError!*Catalog {
        if (s.acquire(kind)) |c| {
            if (s.usable(kind, c)) return c;
            c.release();
        }
        s.refresh(kind) catch |e| {
            if (s.acquire(kind)) |old| if (s.authMatches(old)) return old else old.release();
            return e;
        };
        return s.acquire(kind) orelse error.Failed;
    }

    fn usable(s: *CatalogStore, kind: CatalogKind, c: *Catalog) bool {
        return !s.slots.getPtr(kind).invalid.load(.acquire) and c.isFresh(nowMs(s.io)) and s.authMatches(c);
    }

    fn authMatches(s: *CatalogStore, c: *const Catalog) bool {
        if (c.scope == .public) return true;
        const cur = s.auth_context.load(.acquire);
        return c.auth_context == (if (cur == 0) null else cur);
    }

    /// Switches the auth context (issuer + subject hash, or token
    /// fingerprint). Private catalogs of another context are never served.
    pub fn setAuthContext(s: *CatalogStore, ctx: ?u64) void {
        _ = s.auth_context.swap(ctx orelse 0, .acq_rel);
    }

    /// Marks `kind` stale; the next `get` walks again.
    pub fn invalidate(s: *CatalogStore, kind: CatalogKind) void {
        s.slots.getPtr(kind).invalid.store(true, .release);
    }

    /// Invalidates every catalog (reconnect).
    pub fn invalidateAll(s: *CatalogStore) void {
        for (std.enums.values(CatalogKind)) |k| s.invalidate(k);
    }

    /// Feed every server notification here: `*/list_changed` invalidates
    /// and schedules a debounced refresh of a catalog fetched before (one
    /// nobody asked for stays unfetched).
    pub fn onNotification(s: *CatalogStore, n: protocol.Notification) void {
        const kinds = CatalogKind.fromListChanged(n) orelse return;
        for (kinds) |k| {
            s.invalidate(k);
            if (s.slots.getPtr(k).current.load(.acquire) != null) s.scheduleRefresh(k);
        }
    }

    /// Feed failed tool calls here: a header mismatch or an unknown tool
    /// means the tool catalog is out of date.
    pub fn noteCallError(s: *CatalogStore, err: anyerror, info: ?*const Client.ErrorInfo) void {
        const unknown_tool = err == error.ServerError and info != null and info.?.code == protocol.errors.invalid_params;
        if (err == error.HeaderMismatch or unknown_tool) s.invalidate(.tools);
    }

    /// Calls `l` after every publish that changed something.
    pub fn onChange(s: *CatalogStore, l: ChangeListener) Allocator.Error!void {
        s.listeners_mutex.lockUncancelable(s.io);
        defer s.listeners_mutex.unlock(s.io);
        try s.listeners.append(s.gpa, l);
    }

    fn scheduleRefresh(s: *CatalogStore, kind: CatalogKind) void {
        if (s.slots.getPtr(kind).scheduled.swap(true, .acq_rel)) return;
        s.tasks.async(s.io, debounced, .{ s, kind });
    }

    fn debounced(s: *CatalogStore, kind: CatalogKind) void {
        s.io.sleep(s.opts.debounce, .awake) catch {
            s.slots.getPtr(kind).scheduled.store(false, .release);
            return;
        };
        s.slots.getPtr(kind).scheduled.store(false, .release);
        s.refresh(kind) catch {};
    }

    /// Walks every page of `kind`, builds the catalog and publishes it.
    pub fn refresh(s: *CatalogStore, kind: CatalogKind) FetchError!void {
        s.refresh_mutex.lockUncancelable(s.io);
        defer s.refresh_mutex.unlock(s.io);
        const slot = s.slots.getPtr(kind);
        // Clear first: an invalidation during the walk keeps it invalid.
        slot.invalid.store(false, .release);
        const c = s.build(kind) catch |e| {
            slot.invalid.store(true, .release);
            slot.stale.store(true, .release);
            return e;
        };
        slot.stale.store(false, .release);
        s.publish(kind, c);
    }

    fn build(s: *CatalogStore, kind: CatalogKind) FetchError!*Catalog {
        const c = try Catalog.create(s.gpa, s.io, kind);
        errdefer c.destroy();
        const a = c.arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const w = try walk(a, scratch.allocator(), s.fetcher, kind, s.opts, s.io);
        c.fetched_at_ms = w.fetched_at_ms;
        c.complete = w.complete;
        c.warnings = w.warnings;
        c.scope = w.scope;
        if (w.scope == .private) {
            const cur = s.auth_context.load(.acquire);
            c.auth_context = if (cur == 0) null else cur;
        }
        c.fresh_until_ms = if (w.used_input)
            w.fetched_at_ms
        else if (w.min_ttl_ms) |t|
            w.fetched_at_ms + t
        else if (s.opts.legacy)
            (if (s.opts.list_changed.get(kind)) null else w.fetched_at_ms + @as(i64, @intCast(s.opts.heuristic_ttl_ms)))
        else
            w.fetched_at_ms;
        try fill(c, w.items, s.opts.http);
        return c;
    }

    /// Swaps `c` in, then tells the listeners what changed.
    fn publish(s: *CatalogStore, kind: CatalogKind, c: *Catalog) void {
        c.version = s.version.fetchAdd(1, .monotonic) + 1;
        const old = s.slots.getPtr(kind).current.swap(c, .acq_rel);
        // Grace period: no reader is still between loading `old` and
        // taking its reference once the counter has been zero.
        while (s.readers.load(.acquire) != 0) std.atomic.spinLoopHint();
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const d = diff(arena.allocator(), kind, old, c) catch null;
        if (old) |o| o.release();
        const delta = d orelse return;
        if (delta.isEmpty()) return;
        s.listeners_mutex.lockUncancelable(s.io);
        defer s.listeners_mutex.unlock(s.io);
        for (s.listeners.items) |l| l.func(l.ctx, delta, c);
    }

    /// Publishes a catalog built elsewhere (`snapshot.decode` at startup).
    /// The store takes the reference.
    pub fn adopt(s: *CatalogStore, c: *Catalog) void {
        s.publish(c.kind, c);
    }
};

fn nowMs(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

const Walked = struct {
    items: Items,
    fetched_at_ms: i64,
    min_ttl_ms: ?i64 = null,
    scope: M.CacheScope = .public,
    complete: bool = true,
    used_input: bool = false,
    warnings: []const []const u8 = &.{},
};

/// Fetches every page of `kind`. Items are copied into `arena` only as
/// far as the pages hold them; `scratch` holds the pages.
pub fn walk(arena: Allocator, scratch: Allocator, f: Fetcher, kind: CatalogKind, opts: Options, io: Io) FetchError!Walked {
    var restarted = false;
    outer: while (true) {
        var w: Walked = .{ .items = undefined, .fetched_at_ms = nowMs(io) };
        var warnings: std.ArrayList([]const u8) = .empty;
        var tools: std.ArrayList(M.Tool) = .empty;
        var resources: std.ArrayList(M.Resource) = .empty;
        var templates: std.ArrayList(M.ResourceTemplate) = .empty;
        var prompts: std.ArrayList(M.Prompt) = .empty;
        var cursor: ?[]const u8 = null;
        var pages: u32 = 0;
        var total: usize = 0;
        while (true) {
            const page = f.fetch(f.ctx, arena, kind, cursor) catch |e| switch (e) {
                error.InvalidCursor => if (!restarted and cursor != null) {
                    restarted = true;
                    continue :outer;
                } else return e,
                else => return e,
            };
            const t_received = nowMs(io);
            pages += 1;
            const ttl: i64 = @max(0, page.ttl_ms orelse 0);
            if (page.ttl_ms != null or !opts.legacy) {
                const until = t_received + ttl - w.fetched_at_ms;
                w.min_ttl_ms = if (w.min_ttl_ms) |m| @min(m, until) else until;
            }
            if (page.cache_scope == .private) w.scope = .private;
            if (page.used_input) w.used_input = true;
            const room = opts.max_entries - @min(opts.max_entries, total);
            const n = @min(room, page.items.len());
            switch (page.items) {
                .tools => |s| try tools.appendSlice(scratch, s[0..n]),
                .resources => |s| try resources.appendSlice(scratch, s[0..n]),
                .templates => |s| try templates.appendSlice(scratch, s[0..n]),
                .prompts => |s| try prompts.appendSlice(scratch, s[0..n]),
            }
            total += n;
            const next = page.next_cursor orelse break;
            if (n < page.items.len() or total >= opts.max_entries) {
                w.complete = false;
                try warnings.append(arena, try std.fmt.allocPrint(arena, "stopped at {d} entries; the server lists more", .{opts.max_entries}));
                break;
            }
            if (pages >= opts.max_pages) {
                w.complete = false;
                try warnings.append(arena, try std.fmt.allocPrint(arena, "stopped after {d} pages; the server lists more", .{opts.max_pages}));
                break;
            }
            cursor = try arena.dupe(u8, next);
        }
        w.items = switch (kind) {
            .tools => .{ .tools = try arena.dupe(M.Tool, tools.items) },
            .resources => .{ .resources = try arena.dupe(M.Resource, resources.items) },
            .templates => .{ .templates = try arena.dupe(M.ResourceTemplate, templates.items) },
            .prompts => .{ .prompts = try arena.dupe(M.Prompt, prompts.items) },
        };
        w.warnings = warnings.items;
        return w;
    }
}

/// Builds `c`'s entries, keys, fingerprints and index from `items`.
pub fn fill(c: *Catalog, items: Items, http: bool) Allocator.Error!void {
    return fillOpts(c, items, .{ .http = http });
}

/// `fill` with hygiene options (snapshots compile lazily).
pub fn fillOpts(c: *Catalog, items: Items, opts: hygiene.Options) Allocator.Error!void {
    const a = c.arena.allocator();
    var keys: std.ArrayList([]const u8) = .empty;
    var prints: std.ArrayList(u64) = .empty;
    switch (items) {
        .tools => |defs| {
            var entries: std.ArrayList(ToolEntry) = try .initCapacity(a, defs.len);
            var excluded: std.ArrayList(Excluded) = .empty;
            for (defs) |d| {
                if (c.index.contains(d.name)) {
                    try excluded.append(a, .{ .name = d.name, .reason = "duplicate name; the first definition is kept" });
                    continue;
                }
                switch (try hygiene.check(a, d, opts)) {
                    .excluded => |r| try excluded.append(a, .{ .name = d.name, .reason = r }),
                    .kept => |e| {
                        try c.index.put(a, d.name, @intCast(entries.items.len));
                        entries.appendAssumeCapacity(e);
                        try keys.append(a, d.name);
                        try prints.append(a, e.fingerprint);
                    },
                }
            }
            c.entries = entries.items;
            c.excluded = excluded.items;
        },
        inline .resources, .templates, .prompts => |list, tag| {
            var kept: std.ArrayList(@typeInfo(@TypeOf(list)).pointer.child) = .empty;
            for (list) |item| {
                const key = switch (tag) {
                    .resources => item.uri,
                    .templates => item.uri_template,
                    else => item.name,
                };
                if (c.index.contains(key)) continue;
                try c.index.put(a, key, @intCast(kept.items.len));
                try kept.append(a, item);
                try keys.append(a, key);
                const v = protocol.codec.toValue(a, item) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => Value.null,
                };
                try prints.append(a, schema.hashValue(v));
            }
            @field(c, @tagName(tag)) = kept.items;
        },
    }
    c.keys = keys.items;
    c.prints = prints.items;
}

/// The names added, removed and changed from `old` to `new`.
pub fn diff(arena: Allocator, kind: CatalogKind, old: ?*const Catalog, new: *const Catalog) Allocator.Error!Delta {
    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;
    for (new.keys, new.prints) |k, p| {
        const i = if (old) |o| o.indexOf(k) else null;
        if (i) |j| {
            if (old.?.prints[j] != p) try changed.append(arena, k);
        } else try added.append(arena, k);
    }
    if (old) |o| for (o.keys) |k| if (new.indexOf(k) == null) try removed.append(arena, k);
    return .{ .kind = kind, .added = added.items, .removed = removed.items, .changed = changed.items };
}
