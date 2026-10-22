//! The effective keymap: every binding layer (`builtin_default`, `preset`,
//! `mode_layer`, `extension`, `user`) loaded into one priority-ordered list
//! with removals applied, plus a first-stroke index for the resolver.
//!
//! A layer document is a ZON array of entries:
//!
//! ```zig
//! .{
//!     .{ .key = "mod+shift+p", .command = "workbench.showCommands" },
//!     .{ .key = "mod+k mod+s", .command = "workbench.openKeybindings" },
//!     .{ .key = "ctrl+w", .command = null, .when = "terminalFocus" },     // disable: pass through
//!     .{ .key = "mod+d", .command = "-editor.addSelectionToNextMatch" },   // removal
//!     .{ .key = "ctrl+g", .macos = "cmd+l", .command = "editor.goToLine", .args = .{ .line = 1 } },
//! }
//! ```
//!
//! See `docs/keybindings.md`.

const std = @import("std");
const keyspec = @import("keyspec.zig");
const zon_load = @import("../zon_load.zig");
const diag = @import("../diag.zig");
const Value = @import("../value.zig").Value;
const registry = @import("../commands/registry.zig");
const context = @import("../when/context.zig");
const When = @import("../when/when.zig").When;

const Allocator = std.mem.Allocator;
const Diags = diag.Diags;
const Span = diag.Span;
const Node = zon_load.Node;
const KeySpec = keyspec.KeySpec;
const Platform = keyspec.Platform;
const CommandId = registry.CommandId;
const CommandRegistry = registry.CommandRegistry;
const ContextKeyService = context.ContextKeyService;

/// Binding layers, lowest priority first.
pub const LayerKind = enum(u8) { builtin_default, preset, mode_layer, extension, user };

/// One layer document to load.
pub const LayerInput = struct {
    layer: LayerKind,
    source_path: ?[]const u8 = null,
    doc: *const zon_load.Doc,
    /// Owning extension id for `extension` layers.
    owner: ?[]const u8 = null,
};

/// One effective binding. Later entries in `Keymap.bindings` win.
pub const Binding = struct {
    spec: KeySpec,
    /// Command id text; "" for a disable binding.
    command: []const u8,
    /// Resolved id; `none` for disable bindings and for ids not registered yet.
    id: CommandId,
    /// The id is not registered (yet); the binding is inert until it is.
    unresolved: bool = false,
    when: ?*const When = null,
    /// Canonical ZON text of `args`, interned in the registry.
    arg: ?[]const u8 = null,
    layer: LayerKind,
    source_path: ?[]const u8 = null,
    span: Span = .none,

    /// Whether this binding disables lower ones (`command = null` or "").
    pub fn isDisable(b: *const Binding) bool {
        return b.command.len == 0;
    }

    /// Whether this binding can fire.
    pub fn live(b: *const Binding) bool {
        return !b.unresolved;
    }
};

/// The loaded keymap. Immutable after `build` except for `relink`.
pub const Keymap = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    reg: *CommandRegistry,
    bindings: []Binding,
    /// First stroke (`Stroke.pack`) → binding indices, highest priority first.
    index: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    whens: std.ArrayList(*When) = .empty,
    /// Registry generation the ids were resolved at.
    reg_generation: u64,
    generation: u64,

    var next_generation = std.atomic.Value(u64).init(1);

    /// Loads `layers` (in any order; sorted by `LayerKind`, stable) into a
    /// keymap. Entry problems are reported to `diags` and skip the entry.
    pub fn build(gpa: Allocator, layers: []const LayerInput, reg: *CommandRegistry, ctx: *ContextKeyService, plat: Platform, diags: *Diags) !*Keymap {
        const km = try gpa.create(Keymap);
        errdefer gpa.destroy(km);
        km.* = .{ .gpa = gpa, .arena = .init(gpa), .reg = reg, .bindings = &.{}, .reg_generation = reg.generation(), .generation = next_generation.fetchAdd(1, .monotonic) };
        errdefer km.freeParts();
        const a = km.arena.allocator();

        const order = try gpa.alloc(u32, layers.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, layers, struct {
            fn lt(ls: []const LayerInput, x: u32, y: u32) bool {
                const lx = @intFromEnum(ls[x].layer);
                const ly = @intFromEnum(ls[y].layer);
                return lx < ly or (lx == ly and x < y);
            }
        }.lt);

        var list: std.ArrayList(Binding) = .empty;
        defer list.deinit(gpa);
        errdefer for (list.items) |b| if (b.arg) |t| reg.releaseArgs(t);
        for (order) |li| {
            const in = layers[li];
            const entries = switch (in.doc.root.v) {
                .array => |xs| xs,
                else => {
                    diags.add(in.doc.root.span, .err, "a keybindings file is an array of entries", .{});
                    continue;
                },
            };
            for (entries) |e| try km.loadEntry(a, in, e, plat, ctx, &list, diags);
        }
        km.bindings = try a.dupe(Binding, list.items);
        try km.buildIndex();
        return km;
    }

    fn loadEntry(km: *Keymap, a: Allocator, in: LayerInput, e: Node, plat: Platform, ctx: *ContextKeyService, list: *std.ArrayList(Binding), diags: *Diags) !void {
        if (e.v != .object) {
            diags.add(e.span, .err, "a keybinding entry is an object", .{});
            return;
        }
        for (e.v.object) |f| {
            const known = for ([_][]const u8{ "key", "linux", "windows", "macos", "command", "when", "args" }) |k| {
                if (std.mem.eql(u8, f.key, k)) break true;
            } else false;
            if (!known) diags.add(f.key_span, .warning, "unknown keybinding field '{s}'", .{f.key});
        }
        const plat_field = switch (plat) {
            .linux => "linux",
            .windows => "windows",
            .macos => "macos",
        };
        const key_node = e.get(plat_field) orelse e.get("key") orelse {
            diags.add(e.span, .err, "keybinding has no 'key'", .{});
            return;
        };
        const key_text = switch (key_node.v) {
            .string => |s| s,
            else => {
                diags.add(key_node.span, .err, "'key' is a string", .{});
                return;
            },
        };
        const cmd_node = e.get("command") orelse {
            diags.add(e.span, .err, "keybinding has no 'command'", .{});
            return;
        };
        const command: []const u8 = switch (cmd_node.v) {
            .null => "",
            .string => |s| s,
            else => {
                diags.add(cmd_node.span, .err, "'command' is a string or null", .{});
                return;
            },
        };
        var when: ?*When = null;
        if (e.get("when")) |wn| switch (wn.v) {
            .string => |s| if (s.len > 0) {
                const errors_before = diags.errorCount();
                var sub = Diags.init(km.gpa);
                defer sub.deinit();
                const w = When.compile(km.gpa, s, ctx, &sub) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidWhen => null,
                };
                // Re-base the clause's diagnostics onto the file (inside the quotes).
                for (sub.items()) |d| diags.add(.{ .start = wn.span.start + 1 + d.span.start, .end = wn.span.start + 1 + d.span.end }, d.severity, "{s}", .{d.message});
                if (w == null or diags.errorCount() != errors_before) return;
                const wp = try km.gpa.create(When);
                wp.* = w.?;
                try km.whens.append(km.gpa, wp);
                when = wp;
            },
            .null => {},
            else => {
                diags.add(wn.span, .err, "'when' is a string", .{});
                return;
            },
        };

        // Removal.
        if (command.len > 0 and command[0] == '-') {
            const target = command[1..];
            var spec: ?KeySpec = null;
            if (key_text.len > 0) {
                spec = parseKey(km.gpa, key_text, key_node.span, plat, diags) orelse return;
            }
            var i: usize = 0;
            var removed: usize = 0;
            while (i < list.items.len) {
                const b = &list.items[i];
                const hit = std.mem.eql(u8, b.command, target) and
                    (spec == null or b.spec.eql(spec.?)) and
                    (when == null or (b.when != null and std.mem.eql(u8, b.when.?.text, when.?.text)));
                if (hit) {
                    _ = list.orderedRemove(i);
                    removed += 1;
                } else i += 1;
            }
            if (removed == 0) diags.add(cmd_node.span, .warning, "removal of '{s}' matches no binding", .{target});
            return;
        }

        const spec = parseKey(km.gpa, key_text, key_node.span, plat, diags) orelse return;
        var b: Binding = .{ .spec = spec, .command = try a.dupe(u8, command), .id = .none, .when = when, .layer = in.layer, .source_path = in.source_path, .span = e.span };
        if (command.len > 0) {
            if (km.reg.lookup(command)) |id| {
                b.id = id;
            } else {
                b.unresolved = true;
                diags.add(cmd_node.span, .warning, "command '{s}' is not registered (yet)", .{command});
            }
        }
        if (e.get("args")) |an| if (an.v != .null) {
            const v = try (try zon_load.toValue(a, an)).clone(a);
            var aw: std.Io.Writer.Allocating = .init(a);
            v.writeZon(&aw.writer) catch return error.OutOfMemory;
            const text = aw.written();
            try km.reg.internArgs(text, v);
            b.arg = text;
        };
        try list.append(km.gpa, b);
    }

    fn buildIndex(km: *Keymap) !void {
        const a = km.arena.allocator();
        var tmp: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
        defer {
            var it = tmp.valueIterator();
            while (it.next()) |l| l.deinit(km.gpa);
            tmp.deinit(km.gpa);
        }
        var i = km.bindings.len;
        while (i > 0) {
            i -= 1;
            const gop = try tmp.getOrPut(km.gpa, km.bindings[i].spec.strokes[0].pack());
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(km.gpa, @intCast(i));
        }
        try km.index.ensureTotalCapacity(a, tmp.count());
        var it = tmp.iterator();
        while (it.next()) |kv| km.index.putAssumeCapacity(kv.key_ptr.*, try a.dupe(u32, kv.value_ptr.items));
    }

    /// Bindings whose first stroke is `s`, highest priority first.
    pub fn byFirst(km: *const Keymap, s: keyspec.Stroke) []const u32 {
        return km.index.get(s.pack()) orelse &.{};
    }

    /// Re-resolves ids not registered at build time (an extension registered
    /// its commands later). Cheap when the registry generation is unchanged.
    pub fn relink(km: *Keymap) void {
        const g = km.reg.generation();
        if (g == km.reg_generation) return;
        km.reg_generation = g;
        for (km.bindings) |*b| {
            if (b.command.len == 0) continue;
            if (km.reg.lookup(b.command)) |id| {
                b.id = id;
                b.unresolved = false;
            } else {
                b.id = .none;
                b.unresolved = true;
            }
        }
    }

    fn freeParts(km: *Keymap) void {
        for (km.bindings) |b| if (b.arg) |t| km.reg.releaseArgs(t);
        for (km.whens.items) |w| {
            w.deinit();
            km.gpa.destroy(w);
        }
        km.whens.deinit(km.gpa);
        km.arena.deinit();
    }

    /// Frees the keymap and releases its interned args.
    pub fn deinit(km: *Keymap) void {
        km.freeParts();
        km.gpa.destroy(km);
    }
};

/// Parses a key spec, re-basing its diagnostics onto the string literal.
fn parseKey(gpa: Allocator, text: []const u8, lit: Span, plat: Platform, diags: *Diags) ?KeySpec {
    var sub = Diags.init(gpa);
    defer sub.deinit();
    const spec = keyspec.parse(text, plat, &sub);
    for (sub.items()) |d| diags.add(.{ .start = lit.start + 1 + d.span.start, .end = lit.start + 1 + d.span.end }, d.severity, "{s}", .{d.message});
    return spec;
}
