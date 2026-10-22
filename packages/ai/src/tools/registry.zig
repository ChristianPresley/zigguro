//! `ToolRegistry` (E10.F06.S01.T01): every tool the harness knows, from
//! built-ins, same-package exporters (E07–E09) and MCP servers (E11).
//!
//! Sources are listed again only when one reports a change; each listing
//! becomes an immutable `Generation` that stays alive until the registry
//! is freed, so a toolset built from it never dangles. Names are checked
//! against `^[a-zA-Z0-9_.-]{1,64}$`. MCP tools become
//! `mcp__<server>__<tool>`; a longer name is cut to 55 bytes plus
//! `_<8 hex>` of its hash, and `originalName` maps it back.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ToolSpec = proto.ToolSpec;

pub const max_name_len = 64;

/// Called by a source when its tools change (MCP `list_changed`).
pub const ChangedCb = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
};

/// Where a source sits in the tool order.
pub const SourceKind = enum { builtin, package, mcp };

/// A provider of tools.
pub const ToolSource = struct {
    /// For MCP sources, the configured server name.
    name: []const u8,
    ctx: *anyopaque,
    /// Appends the source's tools to `out` (unmanaged; `gpa` is the
    /// allocator to append with). Strings are copied by the registry.
    list: *const fn (ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(ToolSpec)) anyerror!void,
    subscribe_changed: ?*const fn (ctx: *anyopaque, cb: ChangedCb) void = null,
    /// Prefixed to every tool name. MCP sources default to
    /// `mcp__<server>__`.
    namespace: ?[]const u8 = null,
    kind: SourceKind = .package,
};

/// One listing of every source.
pub const Generation = struct {
    arena: std.heap.ArenaAllocator,
    id: u64,
    /// Built-ins in list order, then package exporters in registration
    /// order, then MCP tools sorted by (server, tool).
    specs: []const ToolSpec,
    /// Exposed name → original tool name, for MCP tools.
    originals: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Skipped tools and why (bad names, collisions, failed sources).
    warnings: []const []const u8,

    pub fn find(g: *const Generation, name: []const u8) ?*const ToolSpec {
        for (g.specs) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
};

pub const ToolRegistry = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    sources: std.ArrayList(ToolSource) = .empty,
    generations: std.ArrayList(*Generation) = .empty,
    dirty: std.atomic.Value(bool) = .init(true),
    next_id: u64 = 1,

    pub fn init(gpa: Allocator, io: Io) ToolRegistry {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(r: *ToolRegistry) void {
        for (r.generations.items) |g| {
            g.arena.deinit();
            r.gpa.destroy(g);
        }
        r.generations.deinit(r.gpa);
        r.sources.deinit(r.gpa);
    }

    /// Adds a source; the next `snapshot` lists it.
    pub fn addSource(r: *ToolRegistry, s: ToolSource) Allocator.Error!void {
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            try r.sources.append(r.gpa, s);
        }
        if (s.subscribe_changed) |sub| sub(s.ctx, .{ .ctx = r, .changed = changed });
        r.markChanged();
    }

    /// The next `snapshot` lists the sources again.
    pub fn markChanged(r: *ToolRegistry) void {
        r.dirty.store(true, .release);
    }

    fn changed(ctx: *anyopaque) void {
        const r: *ToolRegistry = @ptrCast(@alignCast(ctx));
        r.markChanged();
    }

    /// The current generation, listing the sources first if one changed.
    pub fn snapshot(r: *ToolRegistry) Allocator.Error!*const Generation {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.dirty.swap(false, .acq_rel) or r.generations.items.len == 0) {
            const g = r.rebuild() catch |e| {
                r.dirty.store(true, .release);
                return e;
            };
            try r.generations.append(r.gpa, g);
        }
        return r.generations.items[r.generations.items.len - 1];
    }

    fn rebuild(r: *ToolRegistry) Allocator.Error!*Generation {
        const g = try r.gpa.create(Generation);
        g.* = .{ .arena = .init(r.gpa), .id = r.next_id, .specs = &.{}, .warnings = &.{} };
        errdefer {
            g.arena.deinit();
            r.gpa.destroy(g);
        }
        r.next_id += 1;
        const a = g.arena.allocator();
        var specs: std.ArrayList(ToolSpec) = .empty;
        var warnings: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;

        for ([_]SourceKind{ .builtin, .package, .mcp }) |kind| {
            const start = specs.items.len;
            for (r.sources.items) |src| {
                if (src.kind != kind) continue;
                var listed: std.ArrayList(ToolSpec) = .empty;
                src.list(src.ctx, a, &listed) catch |e| {
                    try warnings.append(a, try std.fmt.allocPrint(a, "tool source {s} failed: {s}", .{ src.name, @errorName(e) }));
                    continue;
                };
                const server = if (kind == .mcp) try sanitize(a, src.name) else "";
                for (listed.items) |spec| {
                    var s = spec;
                    s.description = try a.dupe(u8, spec.description);
                    s.input_schema_json = try a.dupe(u8, spec.input_schema_json);
                    if (spec.output_schema_json) |o| s.output_schema_json = try a.dupe(u8, o);
                    if (spec.native) |n| s.native = .{ .provider = n.provider, .json = try a.dupe(u8, n.json) };
                    if (kind == .mcp) {
                        s.origin = .{ .mcp = try a.dupe(u8, src.name) };
                        const full = try std.fmt.allocPrint(a, "{s}{s}", .{ src.namespace orelse try std.fmt.allocPrint(a, "mcp__{s}__", .{server}), try sanitize(a, spec.name) });
                        s.name = try shorten(a, full);
                        try g.originals.put(a, s.name, try a.dupe(u8, spec.name));
                    } else {
                        s.name = if (src.namespace) |ns| try std.fmt.allocPrint(a, "{s}{s}", .{ ns, spec.name }) else try a.dupe(u8, spec.name);
                        if (!validName(s.name)) {
                            try warnings.append(a, try std.fmt.allocPrint(a, "tool {s} from {s} skipped: invalid name", .{ s.name, src.name }));
                            continue;
                        }
                    }
                    if (seen.contains(s.name)) {
                        try warnings.append(a, try std.fmt.allocPrint(a, "tool {s} from {s} skipped: the name is already taken", .{ s.name, src.name }));
                        continue;
                    }
                    try seen.put(a, s.name, {});
                    try specs.append(a, s);
                }
            }
            if (kind == .mcp) std.mem.sort(ToolSpec, specs.items[start..], g, mcpLess);
        }
        g.specs = specs.items;
        g.warnings = warnings.items;
        return g;
    }

    fn mcpLess(g: *const Generation, x: ToolSpec, y: ToolSpec) bool {
        const sx = x.origin.mcp;
        const sy = y.origin.mcp;
        return switch (std.mem.order(u8, sx, sy)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, g.originals.get(x.name).?, g.originals.get(y.name).?),
        };
    }

    /// The tool name an MCP server knows `exposed` by.
    pub fn originalName(r: *ToolRegistry, exposed: []const u8) ?[]const u8 {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.generations.items.len == 0) return null;
        return r.generations.items[r.generations.items.len - 1].originals.get(exposed);
    }
};

/// True for `^[a-zA-Z0-9_.-]{1,64}$`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| if (!nameChar(c)) return false;
    return true;
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

/// Replaces characters outside the name alphabet with `_`.
pub fn sanitize(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try a.dupe(u8, if (s.len == 0) "_" else s);
    for (out) |*c| if (!nameChar(c.*)) {
        c.* = '_';
    };
    return out;
}

/// `name` if it fits in 64 bytes, else its first 55 bytes, `_` and 8 hex
/// digits of its hash.
pub fn shorten(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (name.len <= max_name_len) return name;
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, name));
    return std.fmt.allocPrint(a, "{s}_{x:0>8}", .{ name[0 .. max_name_len - 9], h });
}
