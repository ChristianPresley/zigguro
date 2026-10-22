//! One settings layer: a parsed file (or a list of key/values) normalized
//! into `(SettingId, language block) → Value` entries, validated against the
//! schema with scope and trust enforcement. Layers are immutable once built
//! and reference-counted, because several snapshots may share one.
//!
//! Normalization: nested objects whose path is not itself a declared key are
//! flattened (`.editor = .{ .tabSize = 2 }` → `editor.tabSize`); a path that
//! *is* a declared setting keeps its object value. `.@"[zig]"` and
//! `.@"[zig][zon]"` blocks hold language overrides.

const std = @import("std");
const schema = @import("schema.zig");
const zon_load = @import("zon_load.zig");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Value = schema.Value;
const SettingId = schema.SettingId;
const Diags = diag.Diags;
const Span = diag.Span;

/// Layer precedence, low to high. See `docs/settings-model.md`.
pub const LayerKind = enum(u8) { default, user, workspace, workspace_local, folder, editorconfig, cli, policy };

/// A workspace folder (E08 assigns these; 0-based).
pub const FolderId = enum(u32) { _ };

/// A key/value given directly (cli, policy, editorconfig and importers).
pub const KV = struct {
    key: []const u8,
    value: Value,
    /// Language block such as "[zig]", or null.
    lang: ?[]const u8 = null,
};

/// What to build a layer from.
pub const LayerSource = struct {
    kind: LayerKind,
    /// File path, for diagnostics and the source editor.
    path: ?[]const u8 = null,
    /// Required for `.folder` and `.editorconfig` layers.
    folder: ?FolderId = null,
    /// A parsed file. Borrowed during `build`; values are copied.
    doc: ?*const zon_load.Doc = null,
    /// Or plain values (copied).
    values: ?[]const KV = null,
};

/// One validated setting value in a layer.
pub const Entry = struct {
    id: SettingId,
    value: Value,
    /// The full bracket string ("[zig][zon]") or null for non-language values.
    lang_block: ?[]const u8 = null,
    /// Languages of `lang_block`.
    langs: []const []const u8 = &.{},
    /// Value span in the layer file (zero span for KV sources).
    span: Span = .none,
    /// A restricted key from a workspace or folder layer: applies only
    /// while the workspace is trusted (E16).
    restricted: bool = false,

    /// Whether the snapshot must skip this entry.
    pub fn skipped(e: *const Entry, trusted: bool) bool {
        return e.restricted and !trusted;
    }
};

/// An immutable, reference-counted layer.
pub const Layer = struct {
    arena: std.heap.ArenaAllocator,
    kind: LayerKind,
    path: ?[]const u8,
    folder: ?FolderId,
    /// Sorted by id, then non-language before language entries.
    entries: []const Entry,
    /// Diagnostics found while building (validation, scope, unknown keys).
    diags: Diags,
    refs: std.atomic.Value(u32) = .init(1),

    /// Adds a reference.
    pub fn retain(l: *Layer) *Layer {
        _ = l.refs.fetchAdd(1, .monotonic);
        return l;
    }

    /// Drops a reference; frees the layer when it was the last one.
    pub fn release(l: *Layer, gpa: Allocator) void {
        if (l.refs.fetchSub(1, .acq_rel) != 1) return;
        l.diags.deinit();
        var a = l.arena;
        gpa.destroy(l);
        a.deinit();
    }

    /// Entries for `id` (a contiguous run).
    pub fn entriesFor(l: *const Layer, id: SettingId) []const Entry {
        const lo = std.sort.lowerBound(Entry, l.entries, id, cmpId);
        var hi = lo;
        while (hi < l.entries.len and l.entries[hi].id == id) hi += 1;
        return l.entries[lo..hi];
    }

    fn cmpId(id: SettingId, e: Entry) std.math.Order {
        return std.math.order(id.index(), e.id.index());
    }
};

/// Workspace trust as seen by the store (E16 `ProjectTrust` plugs in here).
pub const TrustPort = struct {
    ctx: ?*anyopaque,
    isTrustedFn: *const fn (ctx: ?*anyopaque, folder: ?FolderId) bool,

    /// Everything untrusted (the safe default until E16 is wired).
    pub const untrusted: TrustPort = .{ .ctx = null, .isTrustedFn = struct {
        fn f(_: ?*anyopaque, _: ?FolderId) bool {
            return false;
        }
    }.f };

    /// Everything trusted (tests and `--trust-all` sessions).
    pub const trusted: TrustPort = .{ .ctx = null, .isTrustedFn = struct {
        fn f(_: ?*anyopaque, _: ?FolderId) bool {
            return true;
        }
    }.f };

    /// Whether `folder` (or the workspace when null) is trusted.
    pub fn isTrusted(t: TrustPort, folder: ?FolderId) bool {
        return t.isTrustedFn(t.ctx, folder);
    }
};

/// Builds a layer. Invalid values are skipped with diagnostics so that the
/// key falls back to the next lower layer; other keys still load.
pub fn build(gpa: Allocator, reg: *const schema.SchemaRegistry, src: LayerSource) error{OutOfMemory}!*Layer {
    const l = try gpa.create(Layer);
    l.* = .{
        .arena = .init(gpa),
        .kind = src.kind,
        .path = null,
        .folder = src.folder,
        .entries = &.{},
        .diags = .init(gpa),
    };
    errdefer l.release(gpa);
    const a = l.arena.allocator();
    if (src.path) |p| l.path = try a.dupe(u8, p);
    var b: Builder = .{ .a = a, .reg = reg, .layer = l };
    if (src.doc) |doc| {
        switch (doc.root.v) {
            .object => |fields| for (fields) |f| try b.top(f),
            else => l.diags.add(doc.root.span, .err, "a settings file must be a struct literal `.{{ ... }}`", .{}),
        }
    }
    if (src.values) |kvs| for (kvs) |kv| try b.kv(kv);
    std.sort.pdq(Entry, b.out.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            if (x.id != y.id) return x.id.index() < y.id.index();
            return x.lang_block == null and y.lang_block != null;
        }
    }.lt);
    l.entries = b.out.items;
    return l;
}

const Builder = struct {
    a: Allocator,
    reg: *const schema.SchemaRegistry,
    layer: *Layer,
    out: std.ArrayList(Entry) = .empty,

    fn top(b: *Builder, f: zon_load.Field) !void {
        if (isLangBlock(f.key)) {
            const langs = try parseLangs(b.a, f.key);
            const block = try b.a.dupe(u8, f.key);
            switch (f.value.v) {
                .object => |inner| for (inner) |g| try b.walk("", g, block, langs),
                else => b.layer.diags.add(f.value.span, .err, "language block '{s}' must be a struct literal", .{f.key}),
            }
            return;
        }
        try b.walk("", f, null, &.{});
    }

    fn walk(b: *Builder, prefix: []const u8, f: zon_load.Field, block: ?[]const u8, langs: []const []const u8) error{OutOfMemory}!void {
        const path = if (prefix.len == 0) f.key else try std.fmt.allocPrint(b.a, "{s}.{s}", .{ prefix, f.key });
        if (b.reg.lookup(path)) |id| return b.add(id, path, f.value, f.key_span, block, langs);
        if (f.value.v == .object and f.value.v.object.len > 0) {
            for (f.value.v.object) |g| try b.walk(path, g, block, langs);
            return;
        }
        if (b.reg.suggest(path)) |s|
            b.layer.diags.add(f.key_span, .warning, "unknown setting '{s}' (did you mean '{s}'?)", .{ path, s })
        else
            b.layer.diags.add(f.key_span, .warning, "unknown setting '{s}'", .{path});
    }

    fn add(b: *Builder, id: SettingId, key: []const u8, n: zon_load.Node, key_span: Span, block: ?[]const u8, langs: []const []const u8) !void {
        const d = b.reg.def(id);
        if (!b.scopeAllowed(d, key_span, key)) return;
        if (block != null and d.scope != .language_overridable) {
            b.layer.diags.add(key_span, .warning, "'{s}' cannot be set per language", .{key});
            return;
        }
        // Validated values still point into the document; copy them out.
        const v = try ((try b.reg.validate(b.a, id, n, &b.layer.diags)) orelse return).clone(b.a);
        try b.out.append(b.a, .{ .id = id, .value = v, .lang_block = block, .langs = langs, .span = n.span, .restricted = b.isRestricted(d) });
    }

    fn kv(b: *Builder, x: KV) !void {
        const id = b.reg.lookup(x.key) orelse {
            b.layer.diags.add(.none, .warning, "unknown setting '{s}'", .{x.key});
            return;
        };
        const d = b.reg.def(id);
        if (!b.scopeAllowed(d, .none, x.key)) return;
        var buf: [128]u8 = undefined;
        if (schema.checkValue(d, x.value, &buf)) |m| {
            b.layer.diags.add(.none, .err, "'{s}' {s}", .{ x.key, m });
            return;
        }
        const block = if (x.lang) |l| try b.a.dupe(u8, l) else null;
        const langs = if (x.lang) |l| try parseLangs(b.a, l) else &.{};
        try b.out.append(b.a, .{ .id = id, .value = try x.value.clone(b.a), .lang_block = block, .langs = langs, .restricted = b.isRestricted(d) });
    }

    fn isRestricted(b: *const Builder, d: *const schema.SettingDef) bool {
        return d.restricted and switch (b.layer.kind) {
            .workspace, .workspace_local, .folder, .editorconfig => true,
            else => false,
        };
    }

    /// Scope enforcement (see docs/settings-model.md).
    fn scopeAllowed(b: *Builder, d: *const schema.SettingDef, span: Span, key: []const u8) bool {
        const k = b.layer.kind;
        const in_workspace = k == .workspace or k == .workspace_local;
        const in_folder = k == .folder or k == .editorconfig;
        if (in_workspace or in_folder) {
            const ok = switch (d.scope) {
                .application, .machine => false,
                .machine_overridable => true,
                .window => in_workspace,
                .resource, .language_overridable => true,
            };
            if (!ok) {
                b.layer.diags.add(span, .warning, "'{s}' has {s} scope and is ignored in {s} settings", .{ key, @tagName(d.scope), @tagName(k) });
                return false;
            }
        }
        return true;
    }
};

/// Whether `key` is a language block such as `[zig]` or `[zig][zon]`.
pub fn isLangBlock(key: []const u8) bool {
    return key.len >= 3 and key[0] == '[' and key[key.len - 1] == ']';
}

/// The languages of a block string: "[zig][zon]" → { "zig", "zon" }.
pub fn parseLangs(a: Allocator, block: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, block, "[]");
    while (it.next()) |l| try out.append(a, try a.dupe(u8, std.mem.trim(u8, l, " ")));
    return out.items;
}

test "layer: flatten nested and dotted keys, language blocks" {
    const gpa = std.testing.allocator;
    var d = Diags.init(gpa);
    defer d.deinit();
    var doc = try zon_load.loadZon(gpa,
        \\.{
        \\    .editor = .{ .tabSize = 2, .fontSize = 13 },
        \\    .@"files.exclude" = .{ .@"*.o" = true },
        \\    .@"[zig][zon]" = .{ .editor = .{ .tabSize = 4 } },
        \\    .@"editor.tabSiz" = 3,
        \\}
    , &d);
    defer doc.deinit();
    const reg = &schema.test_registry;
    const l = try build(gpa, reg, .{ .kind = .user, .doc = &doc });
    defer l.release(gpa);
    const ts = l.entriesFor(reg.lookup("editor.tabSize").?);
    try std.testing.expectEqual(@as(usize, 2), ts.len);
    try std.testing.expectEqual(@as(i64, 2), ts[0].value.int);
    try std.testing.expectEqualStrings("[zig][zon]", ts[1].lang_block.?);
    try std.testing.expectEqualStrings("zon", ts[1].langs[1]);
    try std.testing.expect(l.entriesFor(reg.lookup("files.exclude").?)[0].value.get("*.o").?.bool);
    try std.testing.expect(l.diags.contains("did you mean 'editor.tabSize'"));
}

test "layer: invalid value skipped, others load" {
    const gpa = std.testing.allocator;
    var d = Diags.init(gpa);
    defer d.deinit();
    var doc = try zon_load.loadZon(gpa, ".{ .@\"editor.tabSize\" = 99, .@\"editor.fontSize\" = 12 }", &d);
    defer doc.deinit();
    const reg = &schema.test_registry;
    const l = try build(gpa, reg, .{ .kind = .user, .doc = &doc });
    defer l.release(gpa);
    try std.testing.expectEqual(@as(usize, 0), l.entriesFor(reg.lookup("editor.tabSize").?).len);
    try std.testing.expectEqual(@as(usize, 1), l.entriesFor(reg.lookup("editor.fontSize").?).len);
    try std.testing.expectEqual(@as(usize, 1), l.diags.errorCount());
}
