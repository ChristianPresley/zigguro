//! The key resolver: turns key events into a command, a pending chord, a
//! pass-through or a swallowed key, using a `Keymap` and the focused
//! widget's context stack. Single-threaded (UI thread); never allocates on
//! the key path except when computing labels for the first time.
//!
//! The E04 adapter maps `Resolution` onto `zg_gui.Resolution`: `none` and
//! `pending` map directly, `action` maps with `ActionId = CommandId`, and
//! `swallow` maps to the `noop` command (its message goes to the status bar).

const std = @import("std");
const keys = @import("keys.zig");
const keyspec = @import("keyspec.zig");
const keymap_mod = @import("keymap.zig");
const registry = @import("../commands/registry.zig");
const context = @import("../when/context.zig");
const store = @import("../store.zig");

const Allocator = std.mem.Allocator;
const Stroke = keyspec.Stroke;
const KeySpec = keyspec.KeySpec;
const Platform = keyspec.Platform;
const Keymap = keymap_mod.Keymap;
const Binding = keymap_mod.Binding;
const CommandId = registry.CommandId;
const KeyContext = context.KeyContext;
const EvalEnv = context.EvalEnv;
const ContextKeyService = context.ContextKeyService;

/// The outcome of one key event.
pub const Resolution = union(enum) {
    /// Not bound here (or explicitly disabled): the focused widget gets the key.
    none,
    /// A chord is in progress; the payload is its label so far ("Ctrl+K").
    pending: []const u8,
    /// Run `id`; `arg` is canonical ZON text interned in the registry.
    action: struct { id: CommandId, arg: ?[]const u8 },
    /// Consume the key without running anything (chord mismatch or Escape
    /// cancelling a chord); the payload is a status message, if any.
    swallow: []const u8,
};

/// What `keyboard.chordMismatch` selects.
pub const Mismatch = enum { swallow, passthrough };

/// Resolver options (from the `keyboard.*` settings).
pub const Options = struct {
    platform: Platform = Platform.of(@import("builtin").os.tag),
    dispatch: keyspec.Dispatch = .auto,
    chord_timeout_ms: u32 = 1000,
    double_tap_ms: u32 = 300,
    mismatch: Mismatch = .swallow,

    /// Reads the `keyboard.*` settings from `snap`, keeping defaults for
    /// settings that are missing.
    pub fn fromSettings(snap: *const store.Snapshot, plat: Platform) Options {
        var o: Options = .{ .platform = plat };
        if (snap.getByKey("keyboard.chordTimeoutMs", .{})) |v| if (v == .int) {
            o.chord_timeout_ms = @intCast(std.math.clamp(v.int, 0, 60_000));
        };
        if (snap.getByKey("keyboard.doubleTapMs", .{})) |v| if (v == .int) {
            o.double_tap_ms = @intCast(std.math.clamp(v.int, 50, 2_000));
        };
        if (snap.getByKey("keyboard.chordMismatch", .{})) |v| if (enumText(v)) |t| {
            o.mismatch = std.meta.stringToEnum(Mismatch, t) orelse o.mismatch;
        };
        if (snap.getByKey("keyboard.dispatch", .{})) |v| if (enumText(v)) |t| {
            o.dispatch = std.meta.stringToEnum(keyspec.Dispatch, t) orelse o.dispatch;
        };
        return o;
    }
};

fn enumText(v: anytype) ?[]const u8 {
    return switch (v) {
        .string, .enum_lit => |s| s,
        else => null,
    };
}

/// A next-stroke hint for the which-key popup.
pub const Continuation = struct {
    /// Label of the remaining strokes ("Ctrl+S").
    label: []const u8,
    id: CommandId,
    command: []const u8,
};

/// The resolver. See the module doc.
pub const Resolver = struct {
    gpa: Allocator,
    keys: *ContextKeyService,
    layout: *const keys.LayoutInfo,
    settings: ?*const store.Snapshot = null,
    opts: Options,
    km: ?*Keymap = null,

    // Chord state.
    pending: std.ArrayList(u32) = .empty,
    depth: u8 = 0,
    pending_exact: ?u32 = null,
    deadline_ns: ?u64 = null,
    pending_label: [96]u8 = undefined,
    pending_label_len: usize = 0,
    /// Result of re-processing a key after a chord fired early.
    deferred: ?Resolution = null,

    // Double-tap state.
    tap_mod: ?keys.Modifier = null,
    tap_clean: bool = false,
    last_tap_mod: ?keys.Modifier = null,
    last_tap_ns: u64 = 0,

    // Labels.
    label_arena: std.heap.ArenaAllocator,
    labels: std.AutoHashMapUnmanaged(CommandId, ?[]const u8) = .empty,
    labels_ctx_gen: u64 = 0,
    labels_km_gen: u64 = 0,
    msg_buf: [128]u8 = undefined,
    scratch: [96]u8 = undefined,

    /// Creates a resolver with no keymap (everything resolves to `none`).
    pub fn init(gpa: Allocator, ctx: *ContextKeyService, layout: *const keys.LayoutInfo, opts: Options) !*Resolver {
        const r = try gpa.create(Resolver);
        r.* = .{ .gpa = gpa, .keys = ctx, .layout = layout, .opts = opts, .label_arena = .init(gpa) };
        return r;
    }

    /// Frees the resolver (not the keymap).
    pub fn deinit(r: *Resolver) void {
        r.pending.deinit(r.gpa);
        r.labels.deinit(r.gpa);
        r.label_arena.deinit();
        r.gpa.destroy(r);
    }

    /// Switches to `km` (the caller owns both keymaps and frees the old one
    /// after this returns). Cancels any pending chord.
    pub fn reload(r: *Resolver, km: *Keymap) void {
        r.km = km;
        r.cancel();
        r.invalidateLabels();
    }

    /// Applies new options (settings changed).
    pub fn setOptions(r: *Resolver, opts: Options) void {
        r.opts = opts;
        r.invalidateLabels();
    }

    /// Sets the settings snapshot used for `config.*` when-clause keys.
    pub fn setSettings(r: *Resolver, snap: ?*const store.Snapshot) void {
        r.settings = snap;
    }

    /// Switches keyboard layout (labels change).
    pub fn setLayout(r: *Resolver, layout: *const keys.LayoutInfo) void {
        r.layout = layout;
        r.invalidateLabels();
    }

    fn cancel(r: *Resolver) void {
        r.pending.clearRetainingCapacity();
        r.depth = 0;
        r.pending_exact = null;
        r.deadline_ns = null;
        r.pending_label_len = 0;
    }

    /// Whether a chord is in progress.
    pub fn isPending(r: *const Resolver) bool {
        return r.depth > 0;
    }

    /// Label of the strokes typed so far in a pending chord.
    pub fn pendingLabel(r: *const Resolver) ?[]const u8 {
        return if (r.depth > 0) r.pending_label[0..r.pending_label_len] else null;
    }

    /// When the app must call `onTimer` (monotonic ns), if at all.
    pub fn deadline(r: *const Resolver) ?u64 {
        return r.deadline_ns;
    }

    /// The resolution of a key re-processed after a chord fired because the
    /// key did not continue it. Call after each `resolve` that returned an
    /// action; null when there is none.
    pub fn takeDeferred(r: *Resolver) ?Resolution {
        defer r.deferred = null;
        return r.deferred;
    }

    /// Fires the pending exact binding once the chord timeout passed.
    pub fn onTimer(r: *Resolver, now_ns: u64) ?Resolution {
        const d = r.deadline_ns orelse return null;
        if (now_ns < d) return null;
        const exact = r.pending_exact orelse return null;
        r.cancel();
        return r.fire(exact);
    }

    fn env(r: *const Resolver, stack: []const KeyContext) EvalEnv {
        return .{ .global = r.keys, .stack = stack, .settings = r.settings };
    }

    fn fire(r: *Resolver, bi: u32) Resolution {
        const b = &r.km.?.bindings[bi];
        if (b.isDisable()) return .none;
        return .{ .action = .{ .id = b.id, .arg = b.arg } };
    }

    /// Resolves one key event against the focused context `stack`
    /// (outermost first).
    pub fn resolve(r: *Resolver, stack: []const KeyContext, ev: keys.KeyInput) Resolution {
        r.deferred = null;
        const km = r.km orelse return .none;
        km.relink();

        // Modifier keys: double-tap tracking only.
        if (keys.modifierOf(ev.usage)) |m| if (ev.usage != keys.alt_right or !ev.mods.alt_gr) {
            switch (ev.action) {
                .press => {
                    r.tap_mod = m;
                    r.tap_clean = true;
                },
                .repeat => r.tap_clean = false,
                .release => if (r.tap_clean and r.tap_mod == m) {
                    r.tap_clean = false;
                    if (r.last_tap_mod == m and ev.t_ns -% r.last_tap_ns <= @as(u64, r.opts.double_tap_ms) * std.time.ns_per_ms) {
                        r.last_tap_mod = null;
                        return r.resolveModTap(stack, m);
                    }
                    r.last_tap_mod = m;
                    r.last_tap_ns = ev.t_ns;
                },
            }
            return .none;
        };
        if (ev.action == .release) return .none;
        r.tap_clean = false;
        r.last_tap_mod = null;

        var cbuf: [4]Stroke = undefined;
        const cands = keyspec.candidates(ev, r.layout, r.opts.dispatch, &cbuf);
        const e = r.env(stack);

        if (r.depth > 0) {
            if (ev.action == .repeat) return .{ .swallow = "" };
            if (ev.usage == keys.escape and ev.mods.bindable().isEmpty()) {
                r.cancel();
                return .{ .swallow = "" };
            }
            return r.continueChord(stack, ev, cands, &e);
        }
        return r.start(cands, &e, ev);
    }

    fn start(r: *Resolver, cands: []const Stroke, e: *const EvalEnv, ev: keys.KeyInput) Resolution {
        const km = r.km.?;
        var exact: ?u32 = null;
        var longer = false;
        for (cands) |c| for (km.byFirst(c)) |bi| {
            const b = &km.bindings[bi];
            if (!b.live()) continue;
            if (b.spec.isModTap()) continue;
            if (ev.action == .repeat) {
                if (b.spec.len != 1) continue;
                if (!b.isDisable() and !km.reg.get(b.id).repeat) continue;
            }
            if (b.when) |w| if (!w.eval(e)) continue;
            if (b.spec.len == 1) {
                if (exact == null or bi > exact.?) exact = bi;
            } else longer = true;
        };
        if (!longer) return if (exact) |x| r.fire(x) else .none;

        // Enter a chord: remember every live continuation.
        r.pending.clearRetainingCapacity();
        for (cands) |c| for (km.byFirst(c)) |bi| {
            const b = &km.bindings[bi];
            if (!b.live() or b.spec.len < 2 or b.spec.isModTap()) continue;
            if (b.when) |w| if (!w.eval(e)) continue;
            if (std.mem.indexOfScalar(u32, r.pending.items, bi) == null) r.pending.append(r.gpa, bi) catch return if (exact) |x| r.fire(x) else .none;
        };
        // A higher-priority exact binding (or a disable) shadows chords that are lower.
        if (exact) |x| {
            var any_higher = false;
            for (r.pending.items) |bi| if (bi > x) {
                any_higher = true;
            };
            if (!any_higher and km.bindings[x].isDisable()) {
                r.pending.clearRetainingCapacity();
                return .none;
            }
        }
        r.depth = 1;
        r.pending_exact = exact;
        r.deadline_ns = if (exact != null) ev.t_ns + @as(u64, r.opts.chord_timeout_ms) * std.time.ns_per_ms else null;
        r.setPendingLabel(r.pending.items[0]);
        return .{ .pending = r.pendingLabel().? };
    }

    fn continueChord(r: *Resolver, stack: []const KeyContext, ev: keys.KeyInput, cands: []const Stroke, e: *const EvalEnv) Resolution {
        const km = r.km.?;
        const d = r.depth;
        var exact: ?u32 = null;
        var longer = false;
        var w: usize = 0;
        for (r.pending.items) |bi| {
            const b = &km.bindings[bi];
            const s = b.spec.strokes[d];
            const hit = for (cands) |c| {
                if (c.eql(s)) break true;
            } else false;
            if (!hit) continue;
            if (b.when) |wc| if (!wc.eval(e)) continue;
            r.pending.items[w] = bi;
            w += 1;
            if (b.spec.len == d + 1) {
                if (exact == null or bi > exact.?) exact = bi;
            } else longer = true;
        }
        r.pending.items.len = w;

        if (w == 0) {
            const prior = r.pending_exact;
            const label = r.pendingLabel().?;
            if (prior) |x| {
                // The key does not continue the chord: fire the prefix binding
                // and process the key on its own.
                r.cancel();
                const res = r.fire(x);
                r.deferred = r.resolve(stack, ev);
                return res;
            }
            var key_buf: [32]u8 = undefined;
            const key_label = strokeLabel(r, cands, &key_buf);
            const msg = std.fmt.bufPrint(&r.msg_buf, "({s}, {s}) is not a command", .{ label, key_label }) catch "";
            r.cancel();
            return switch (r.opts.mismatch) {
                .swallow => .{ .swallow = msg },
                .passthrough => .none,
            };
        }
        if (!longer) {
            r.cancel();
            return r.fire(exact.?);
        }
        r.depth = d + 1;
        r.pending_exact = exact;
        r.deadline_ns = if (exact != null) ev.t_ns + @as(u64, r.opts.chord_timeout_ms) * std.time.ns_per_ms else null;
        r.setPendingLabel(r.pending.items[0]);
        return .{ .pending = r.pendingLabel().? };
    }

    fn resolveModTap(r: *Resolver, stack: []const KeyContext, m: keys.Modifier) Resolution {
        if (r.depth > 0) r.cancel();
        const km = r.km.?;
        const e = r.env(stack);
        const s: Stroke = .{ .kind = .modtap, .code = @intFromEnum(m) };
        for (km.byFirst(s)) |bi| {
            const b = &km.bindings[bi];
            if (!b.live() or !b.spec.isModTap()) continue;
            if (b.when) |w| if (!w.eval(&e)) continue;
            return r.fire(bi);
        }
        return .none;
    }

    fn setPendingLabel(r: *Resolver, bi: u32) void {
        var spec = r.km.?.bindings[bi].spec;
        spec.len = r.depth;
        var w: std.Io.Writer = .fixed(&r.pending_label);
        keyspec.format(spec, r.opts.platform, .label, r.layout, &w) catch {};
        r.pending_label_len = w.end;
    }

    /// Next-stroke hints while a chord is pending (which-key popup). Labels
    /// point into `arena`.
    pub fn continuations(r: *const Resolver, arena: Allocator, stack: []const KeyContext, out: *std.ArrayList(Continuation)) !void {
        if (r.depth == 0) return;
        const km = r.km.?;
        const e = r.env(stack);
        for (r.pending.items) |bi| {
            const b = &km.bindings[bi];
            if (b.when) |w| if (!w.eval(&e)) continue;
            var rest: KeySpec = .{ .len = b.spec.len - r.depth };
            @memcpy(rest.strokes[0..rest.len], b.spec.strokes[r.depth..b.spec.len]);
            var aw: std.Io.Writer.Allocating = .init(arena);
            keyspec.format(rest, r.opts.platform, .label, r.layout, &aw.writer) catch return error.OutOfMemory;
            try out.append(arena, .{ .label = aw.written(), .id = b.id, .command = b.command });
        }
    }

    fn invalidateLabels(r: *Resolver) void {
        r.labels.clearRetainingCapacity();
        _ = r.label_arena.reset(.retain_capacity);
        r.labels_km_gen = if (r.km) |k| k.generation else 0;
        r.labels_ctx_gen = r.keys.generation();
    }

    /// The label of the binding that runs `id` ("Ctrl+Shift+P"): the
    /// highest-priority live binding not shadowed by a higher binding of the
    /// same keys. With `stack`, the binding's when-clause must also hold
    /// there, and the returned slice is valid until the next call; without
    /// it, labels are cached until the keymap, layout or context changes.
    pub fn labelFor(r: *Resolver, id: CommandId, stack: ?[]const KeyContext) ?[]const u8 {
        const km = r.km orelse return null;
        km.relink();
        if (stack) |st| {
            const e = r.env(st);
            const bi = r.findBinding(id, &e) orelse return null;
            var w: std.Io.Writer = .fixed(&r.scratch);
            keyspec.format(km.bindings[bi].spec, r.opts.platform, .label, r.layout, &w) catch return null;
            return w.buffered();
        }
        if (km.generation != r.labels_km_gen or r.keys.generation() != r.labels_ctx_gen) r.invalidateLabels();
        if (r.labels.get(id)) |l| return l;
        const label: ?[]const u8 = if (r.findBinding(id, null)) |bi| blk: {
            var aw: std.Io.Writer.Allocating = .init(r.label_arena.allocator());
            keyspec.format(km.bindings[bi].spec, r.opts.platform, .label, r.layout, &aw.writer) catch return null;
            break :blk aw.written();
        } else null;
        r.labels.put(r.gpa, id, label) catch {};
        return label;
    }

    fn findBinding(r: *const Resolver, id: CommandId, e: ?*const EvalEnv) ?u32 {
        if (id == .none) return null;
        const km = r.km.?;
        var i = km.bindings.len;
        outer: while (i > 0) {
            i -= 1;
            const b = &km.bindings[i];
            if (b.id != id or !b.live()) continue;
            if (e) |env_| if (b.when) |w| if (!w.eval(env_)) continue;
            // Shadowed by a higher binding of the same keys with no or the same clause?
            for (km.bindings[i + 1 ..]) |*h| {
                if (!h.live() or !h.spec.eql(b.spec)) continue;
                if (h.when == null or (b.when != null and std.mem.eql(u8, h.when.?.text, b.when.?.text))) continue :outer;
            }
            return @intCast(i);
        }
        return null;
    }
};

fn strokeLabel(r: *const Resolver, cands: []const Stroke, buf: []u8) []const u8 {
    if (cands.len == 0) return "?";
    // Prefer the logical stroke for the message (what the user sees on the key cap).
    var s = cands[0];
    for (cands) |c| if (c.kind == .logical) {
        s = c;
        break;
    };
    var spec: KeySpec = .{ .len = 1 };
    spec.strokes[0] = s;
    var w: std.Io.Writer = .fixed(buf);
    keyspec.format(spec, r.opts.platform, .label, r.layout, &w) catch {};
    return w.buffered();
}
