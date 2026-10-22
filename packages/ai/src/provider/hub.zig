//! `ProviderHub`: owns the live `Provider` instances. Reads the
//! `ai.providers` settings, resolves keys through the secret store or the
//! environment, builds each provider with the shared `Transport`, wraps it
//! in `guarded()`, tests connections, and rebuilds only changed entries
//! when settings change.
//!
//! `get`/`forModel` read an atomically swapped table and never block.
//! Replaced instances are retired, not freed: a stream that started on the
//! old instance finishes on it, and retired instances with nothing in
//! flight are freed at the next rebuild (or `deinit`). Key values live
//! only in each instance's arena; they never reach logs or warnings.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("Provider.zig");
const events = @import("events.zig");
const request = @import("request.zig");
const tp = @import("transport.zig");
const keyref = @import("keyref.zig");
const ratelimit = @import("ratelimit.zig");
const guard = @import("guarded.zig");
const retry = @import("retry.zig");
const Capabilities = @import("capabilities.zig").Capabilities;
const registry = @import("../models/registry.zig");
const Anthropic = @import("anthropic/Anthropic.zig");
const Responses = @import("openai/Responses.zig");
const Chat = @import("openai/Chat.zig");
const Gemini = @import("gemini/Gemini.zig");

const Allocator = std.mem.Allocator;
const KeyRef = keyref.KeyRef;

pub const Kind = enum {
    anthropic,
    openai_responses,
    openai_chat,
    gemini,

    pub fn providerId(k: Kind) proto.ProviderId {
        return switch (k) {
            inline else => |t| @field(proto.ProviderId, @tagName(t)),
        };
    }

    /// The conventional environment variable, if any.
    pub fn envVar(k: Kind) ?[]const u8 {
        return switch (k) {
            .anthropic => "ANTHROPIC_API_KEY",
            .openai_responses => "OPENAI_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .openai_chat => null,
        };
    }

    /// The default secret name, e.g. `ai/anthropic/default`.
    pub fn defaultSecret(k: Kind) ?[]const u8 {
        return switch (k) {
            .anthropic => "ai/anthropic/default",
            .openai_responses => "ai/openai/default",
            .gemini => "ai/gemini/default",
            .openai_chat => null,
        };
    }

    /// Local servers need no key.
    pub fn needsKey(k: Kind) bool {
        return k != .openai_chat;
    }
};

/// One `ai.providers` entry.
pub const ProviderSettings = struct {
    kind: Kind,
    /// `${secret:name}` | `${env:NAME}` | null.
    key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    dialect: ?[]const u8 = null,
    label: ?[]const u8 = null,
    max_concurrent: ?u8 = null,
    enabled: bool = true,
    extra_headers: []const request.Header = &.{},

    fn hash(s: ProviderSettings) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(@tagName(s.kind));
        inline for (.{ s.key, s.base_url, s.dialect, s.label }) |o| {
            h.update(if (o) |v| v else "\x00null");
            h.update("\x01");
        }
        h.update(&.{ s.max_concurrent orelse 0, @intFromBool(s.max_concurrent != null), @intFromBool(s.enabled) });
        for (s.extra_headers) |x| {
            h.update(x.name);
            h.update("\x00");
            h.update(x.value);
            h.update("\x01");
        }
        return h.final();
    }
};

pub const NamedSettings = struct { id: []const u8, settings: ProviderSettings };

/// Persists a changed entry back to settings (E15).
pub const SettingsWriter = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, id: []const u8, s: ProviderSettings) anyerror!void,
};

/// Receives user-facing warnings (never containing key values) and raw
/// keys to register with the redactor.
pub const Notifier = struct {
    ctx: *anyopaque,
    warn: *const fn (ctx: *anyopaque, msg: []const u8) void,
    redact: *const fn (ctx: *anyopaque, secret: []const u8) void,
};

pub const Deps = struct {
    secrets: keyref.SecretStore,
    environ: *const std.process.Environ.Map,
    transport: tp.Transport,
    limiter: *ratelimit.RateLimiter,
    registry: ?*registry.ModelRegistry = null,
    writer: ?SettingsWriter = null,
    notifier: ?Notifier = null,
    policy: retry.RetryPolicy = .{},
    clock: ratelimit.Clock = .real,
};

pub const ConnectReport = struct {
    ok: bool,
    status: ?u16 = null,
    models_found: u32 = 0,
    message: []const u8,
};

pub const Error = Allocator.Error || keyref.SecretError || error{ UnknownProvider, WriteFailed, Canceled };

const Entry = struct {
    hub: *ProviderHub,
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    settings: ProviderSettings,
    hash: u64,
    /// The guarded provider; `raw` is the unguarded instance (owned by it).
    guarded: Provider,
    raw: Provider,
    inflight: std.atomic.Value(u32) = .init(0),

    fn provider(e: *Entry) Provider {
        return .{ .ptr = e, .vtable = &entry_vtable, .id = e.guarded.id, .caps = e.guarded.caps };
    }

    fn destroy(e: *Entry) void {
        const gpa = e.hub.gpa;
        e.guarded.deinit();
        e.arena.deinit();
        gpa.destroy(e);
    }

    const entry_vtable: Provider.VTable = .{ .stream = stream, .count_tokens = countTokens, .list_models = listModels, .deinit = noDeinit };

    fn noDeinit(_: *anyopaque) void {}

    fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
        const e: *Entry = @ptrCast(@alignCast(ptr));
        _ = e.inflight.fetchAdd(1, .acq_rel);
        defer _ = e.inflight.fetchSub(1, .acq_rel);
        if (e.settings.extra_headers.len == 0) return e.guarded.stream(io, arena, req, sink);
        var r = req.*;
        const hs = arena.alloc(request.Header, req.extra_headers.len + e.settings.extra_headers.len) catch return error.OutOfMemory;
        @memcpy(hs[0..req.extra_headers.len], req.extra_headers);
        @memcpy(hs[req.extra_headers.len..], e.settings.extra_headers);
        r.extra_headers = hs;
        return e.guarded.stream(io, arena, &r, sink);
    }

    fn countTokens(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request) Provider.CountError!u64 {
        const e: *Entry = @ptrCast(@alignCast(ptr));
        _ = e.inflight.fetchAdd(1, .acq_rel);
        defer _ = e.inflight.fetchSub(1, .acq_rel);
        return e.guarded.countTokens(io, arena, req);
    }

    fn listModels(ptr: *anyopaque, io: std.Io, arena: Allocator) Provider.StreamError![]Provider.ModelInfo {
        const e: *Entry = @ptrCast(@alignCast(ptr));
        _ = e.inflight.fetchAdd(1, .acq_rel);
        defer _ = e.inflight.fetchSub(1, .acq_rel);
        return e.guarded.listModels(io, arena);
    }
};

const Table = struct {
    entries: []*Entry,
};

pub const ProviderHub = struct {
    gpa: Allocator,
    deps: Deps,
    mutex: std.Io.Mutex = .init,
    /// Current settings (owned by `settings_arena`).
    settings: []const NamedSettings = &.{},
    settings_arena: std.heap.ArenaAllocator,
    table: std.atomic.Value(*Table),
    old_tables: std.ArrayList(*Table) = .empty,
    retired: std.ArrayList(*Entry) = .empty,
    /// Ids whose entries were skipped for a missing key.
    missing: std.ArrayList([]const u8) = .empty,
    warned_raw: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator, deps: Deps) Allocator.Error!*ProviderHub {
        const h = try gpa.create(ProviderHub);
        errdefer gpa.destroy(h);
        const t = try gpa.create(Table);
        t.* = .{ .entries = &.{} };
        h.* = .{ .gpa = gpa, .deps = deps, .settings_arena = .init(gpa), .table = .init(t) };
        return h;
    }

    pub fn deinit(h: *ProviderHub) void {
        const t = h.table.load(.acquire);
        for (t.entries) |e| e.destroy();
        h.freeTable(t);
        for (h.old_tables.items) |o| h.freeTable(o);
        h.old_tables.deinit(h.gpa);
        for (h.retired.items) |e| e.destroy();
        h.retired.deinit(h.gpa);
        h.freeMissing();
        h.missing.deinit(h.gpa);
        var it = h.warned_raw.keyIterator();
        while (it.next()) |k| h.gpa.free(k.*);
        h.warned_raw.deinit(h.gpa);
        h.settings_arena.deinit();
        h.gpa.destroy(h);
    }

    fn freeTable(h: *ProviderHub, t: *Table) void {
        h.gpa.free(t.entries);
        h.gpa.destroy(t);
    }

    fn freeMissing(h: *ProviderHub) void {
        for (h.missing.items) |m| h.gpa.free(m);
        h.missing.clearRetainingCapacity();
    }

    /// The provider named `id`, already guarded. Never blocks.
    pub fn get(h: *ProviderHub, id: []const u8) ?Provider {
        for (h.table.load(.acquire).entries) |e| if (std.mem.eql(u8, e.id, id)) return e.provider();
        return null;
    }

    /// The first provider serving `model`'s provider kind.
    pub fn forModel(h: *ProviderHub, model: *const registry.ModelInfo) ?Provider {
        for (h.table.load(.acquire).entries) |e| if (e.settings.kind.providerId() == model.provider) return e.provider();
        return null;
    }

    /// Ids of the live providers.
    pub fn ids(h: *ProviderHub, buf: [][]const u8) [][]const u8 {
        const es = h.table.load(.acquire).entries;
        const n = @min(es.len, buf.len);
        for (es[0..n], buf[0..n]) |e, *b| b.* = e.id;
        return buf[0..n];
    }

    /// True when `id` was configured (or defaulted) but has no key.
    pub fn isMissingKey(h: *ProviderHub, io: std.Io, id: []const u8) bool {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        for (h.missing.items) |m| if (std.mem.eql(u8, m, id)) return true;
        return false;
    }

    /// Applies the `ai.providers` setting; an empty list means defaults.
    pub fn onSettingsChanged(h: *ProviderHub, io: std.Io, entries: []const NamedSettings) Error!void {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        errdefer arena.deinit();
        const copy = try copySettings(arena.allocator(), entries);
        try h.rebuildLocked(io, copy, null);
        h.settings_arena.deinit();
        h.settings_arena = arena;
        h.settings = copy;
    }

    /// Resolves a key: explicit `${secret:}` → explicit `${env:}` → the
    /// kind's default secret → its conventional env var. Raw keys are
    /// returned as-is. The result is borrowed (store or environ owned).
    pub fn resolveKey(h: *ProviderHub, io: std.Io, kind: Kind, ref: KeyRef) keyref.SecretError!?[]const u8 {
        switch (ref) {
            .raw => |v| return v,
            .secret => |n| if (try h.deps.secrets.get(io, n)) |v| return v,
            .env => |n| if (h.deps.environ.get(n)) |v| if (v.len > 0) return v,
            .none => {},
        }
        if (kind.defaultSecret()) |n| if (try h.deps.secrets.get(io, n)) |v| return v;
        if (kind.envVar()) |n| if (h.deps.environ.get(n)) |v| if (v.len > 0) return v;
        return null;
    }

    /// `list_models` against the unguarded instance (no retries).
    pub fn testConnection(h: *ProviderHub, io: std.Io, id: []const u8) Error!ConnectReport {
        const e = blk: {
            for (h.table.load(.acquire).entries) |e| if (std.mem.eql(u8, e.id, id)) break :blk e;
            if (h.isMissingKey(io, id)) return .{ .ok = false, .message = "no API key configured" };
            return error.UnknownProvider;
        };
        _ = e.inflight.fetchAdd(1, .acq_rel);
        defer _ = e.inflight.fetchSub(1, .acq_rel);
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        defer arena.deinit();
        const ms = e.raw.listModels(io, arena.allocator()) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => .{ .ok = true, .message = "connected (model listing unsupported)" },
            error.Auth => .{ .ok = false, .status = 401, .message = "authentication failed: check the API key" },
            error.InvalidRequest => .{ .ok = false, .status = 400, .message = "the server rejected the request" },
            error.RateLimited => .{ .ok = false, .status = 429, .message = "rate limited" },
            error.Network, error.Timeout => .{ .ok = false, .message = "could not reach the server" },
            else => .{ .ok = false, .message = "unexpected response from the server" },
        };
        if (h.deps.registry) |r| r.applyApi(e.settings.kind.providerId(), e.raw.caps, ms) catch {};
        return .{ .ok = true, .status = 200, .models_found = @intCast(ms.len), .message = "connected" };
    }

    /// Stores `raw_key` (if given) as `ai/<id>/default`, points the
    /// entry's `key` at it, persists the entry, rebuilds and tests it.
    pub fn connect(h: *ProviderHub, io: std.Io, id: []const u8, raw_key: ?[]const u8, s: ProviderSettings) Error!ConnectReport {
        var name_buf: [128]u8 = undefined;
        var ref_buf: [160]u8 = undefined;
        var settings = s;
        if (raw_key) |k| {
            const name = std.fmt.bufPrint(&name_buf, "ai/{s}/default", .{id}) catch return error.UnknownProvider;
            try h.deps.secrets.put(io, name, k);
            settings.key = (KeyRef{ .secret = name }).format(&ref_buf).?;
        }
        if (h.deps.writer) |w| w.write(w.ctx, id, settings) catch return error.WriteFailed;
        {
            h.mutex.lockUncancelable(io);
            defer h.mutex.unlock(io);
            var list: std.ArrayList(NamedSettings) = .empty;
            defer list.deinit(h.gpa);
            var replaced = false;
            for (h.settings) |x| {
                if (std.mem.eql(u8, x.id, id)) {
                    try list.append(h.gpa, .{ .id = id, .settings = settings });
                    replaced = true;
                } else try list.append(h.gpa, x);
            }
            if (!replaced) try list.append(h.gpa, .{ .id = id, .settings = settings });
            var arena: std.heap.ArenaAllocator = .init(h.gpa);
            errdefer arena.deinit();
            const copy = try copySettings(arena.allocator(), list.items);
            // Rebuild `id` even if its settings text is unchanged (new key).
            try h.rebuildLocked(io, copy, id);
            h.settings_arena.deinit();
            h.settings_arena = arena;
            h.settings = copy;
        }
        return h.testConnection(io, id);
    }

    /// The CLI's message for a provider without a key.
    pub fn missingKeyMessage(buf: []u8, id: []const u8, kind: Kind) []const u8 {
        return std.fmt.bufPrint(buf, "No API key for {s}: set {s} or run `zg ai connect {s}`", .{ id, kind.envVar() orelse "a key", id }) catch "No API key";
    }

    fn defaults(h: *ProviderHub, io: std.Io, a: Allocator) Error![]const NamedSettings {
        var out: std.ArrayList(NamedSettings) = .empty;
        const cands = [_]NamedSettings{
            .{ .id = "anthropic", .settings = .{ .kind = .anthropic } },
            .{ .id = "openai", .settings = .{ .kind = .openai_responses } },
        };
        for (cands) |c| if (try h.resolveKey(io, c.settings.kind, .none) != null) try out.append(a, c);
        return out.items;
    }

    fn rebuildLocked(h: *ProviderHub, io: std.Io, wanted_in: []const NamedSettings, force: ?[]const u8) Error!void {
        var scratch: std.heap.ArenaAllocator = .init(h.gpa);
        defer scratch.deinit();
        const wanted = if (wanted_in.len == 0) try h.defaults(io, scratch.allocator()) else wanted_in;
        const old = h.table.load(.acquire);

        var next: std.ArrayList(*Entry) = .empty;
        errdefer {
            for (next.items) |e| if (std.mem.indexOfScalar(*Entry, old.entries, e) == null) e.destroy();
            next.deinit(h.gpa);
        }
        h.freeMissing();
        for (wanted) |w| {
            if (!w.settings.enabled) continue;
            const hash = w.settings.hash();
            const forced = if (force) |f| std.mem.eql(u8, f, w.id) else false;
            const reuse = for (old.entries) |e| {
                if (!forced and e.hash == hash and std.mem.eql(u8, e.id, w.id)) break e;
            } else null;
            if (reuse) |e| {
                try next.append(h.gpa, e);
                continue;
            }
            const e = (try h.build(io, w)) orelse {
                try h.missing.append(h.gpa, try h.gpa.dupe(u8, w.id));
                continue;
            };
            next.append(h.gpa, e) catch |err| {
                e.destroy();
                return err;
            };
        }
        try h.old_tables.ensureUnusedCapacity(h.gpa, 1);
        try h.retired.ensureUnusedCapacity(h.gpa, h.retired.items.len + old.entries.len);
        const t = try h.gpa.create(Table);
        errdefer h.gpa.destroy(t);
        t.* = .{ .entries = try next.toOwnedSlice(h.gpa) };

        // Free retired instances that finished their streams before this rebuild.
        var i: usize = 0;
        while (i < h.retired.items.len) {
            const e = h.retired.items[i];
            if (e.inflight.load(.acquire) == 0) {
                e.destroy();
                _ = h.retired.swapRemove(i);
            } else i += 1;
        }
        for (old.entries) |e| if (std.mem.indexOfScalar(*Entry, t.entries, e) == null) h.retired.appendAssumeCapacity(e);
        h.table.store(t, .release);
        h.old_tables.appendAssumeCapacity(old);
    }

    fn build(h: *ProviderHub, io: std.Io, w: NamedSettings) Error!?*Entry {
        const e = try h.gpa.create(Entry);
        e.* = .{ .hub = h, .arena = .init(h.gpa), .id = undefined, .settings = undefined, .hash = w.settings.hash(), .guarded = undefined, .raw = undefined };
        var ok = false;
        defer if (!ok) {
            e.arena.deinit();
            h.gpa.destroy(e);
        };
        const a = e.arena.allocator();
        e.id = try a.dupe(u8, w.id);
        e.settings = (try copySettings(a, &.{w}))[0].settings;
        const s = e.settings;

        const ref = KeyRef.parse(s.key);
        if (ref == .raw) h.warnRaw(w.id, ref.raw);
        const key: []const u8 = if (try h.resolveKey(io, s.kind, ref)) |k| try a.dupe(u8, k) else blk: {
            if (s.kind.needsKey()) return null;
            break :blk "";
        };

        const t = h.deps.transport;
        const raw: Provider = switch (s.kind) {
            .anthropic => (try Anthropic.create(h.gpa, t, .{ .base_url = s.base_url orelse "https://api.anthropic.com", .api_key = key })).provider(),
            .openai_responses => (try Responses.create(h.gpa, t, .{ .base_url = s.base_url orelse "https://api.openai.com/v1", .api_key = key })).provider(),
            .gemini => (try Gemini.create(h.gpa, t, .{ .base_url = s.base_url orelse "https://generativelanguage.googleapis.com/v1beta", .api_key = key })).provider(),
            .openai_chat => (try Chat.create(h.gpa, t, .{ .base_url = s.base_url orelse "http://localhost:11434/v1", .api_key = key, .dialect = s.dialect orelse "auto", .label = s.label orelse "" })).provider(),
        };
        try h.deps.limiter.setMaxConcurrent(io, e.id, s.max_concurrent orelse if (s.kind == .openai_chat) 1 else 8);
        e.raw = raw;
        e.guarded = guard.guarded(h.gpa, raw, h.deps.limiter, .{ .instance = e.id, .policy = h.deps.policy, .clock = h.deps.clock }) catch |err| {
            raw.deinit();
            return err;
        };
        ok = true;
        return e;
    }

    fn warnRaw(h: *ProviderHub, id: []const u8, secret: []const u8) void {
        const n = h.deps.notifier orelse return;
        n.redact(n.ctx, secret);
        if (h.warned_raw.contains(id)) return;
        const owned = h.gpa.dupe(u8, id) catch return;
        h.warned_raw.put(h.gpa, owned, {}) catch {
            h.gpa.free(owned);
            return;
        };
        var buf: [256]u8 = undefined;
        n.warn(n.ctx, std.fmt.bufPrint(&buf, "ai.providers.{s}.key holds a raw API key; use \"Move to secret store\" to keep it out of settings", .{id}) catch "a provider key is stored in settings");
    }
};

fn copySettings(a: Allocator, src: []const NamedSettings) Allocator.Error![]NamedSettings {
    const out = try a.alloc(NamedSettings, src.len);
    for (src, out) |x, *y| {
        var s = x.settings;
        inline for (.{ "key", "base_url", "dialect", "label" }) |f| {
            if (@field(x.settings, f)) |v| @field(s, f) = try a.dupe(u8, v);
        }
        const hs = try a.alloc(request.Header, x.settings.extra_headers.len);
        for (x.settings.extra_headers, hs) |hx, *hy| hy.* = .{ .name = try a.dupe(u8, hx.name), .value = try a.dupe(u8, hx.value) };
        s.extra_headers = hs;
        y.* = .{ .id = try a.dupe(u8, x.id), .settings = s };
    }
    return out;
}
