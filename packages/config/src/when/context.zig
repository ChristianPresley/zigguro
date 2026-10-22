//! Context keys: the global key/value table when-clauses read
//! (`editorTextFocus`, `resourceLangId`, ...) plus the focus-chain context
//! stack that E04 provides per key event.

const std = @import("std");
const store = @import("../store.zig");

const Allocator = std.mem.Allocator;

/// A context value.
pub const CtxValue = union(enum) {
    undef,
    bool: bool,
    num: f64,
    /// Owned by whoever set it (the service copies on `set`).
    str: []const u8,
    /// For `in` / `not in`.
    list: []const []const u8,

    /// When-clause truthiness: bool itself, non-zero numbers, non-empty
    /// strings and lists; `undef` is false.
    pub fn truthy(v: CtxValue) bool {
        return switch (v) {
            .undef => false,
            .bool => |b| b,
            .num => |n| n != 0,
            .str => |s| s.len > 0,
            .list => |l| l.len > 0,
        };
    }

    /// The string form used by `==`: VS Code compares after string
    /// conversion, so `true == 'true'` holds. Null for undef and lists.
    pub fn text(v: CtxValue, buf: []u8) ?[]const u8 {
        return switch (v) {
            .undef, .list => null,
            .bool => |b| if (b) "true" else "false",
            .num => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
            .str => |s| s,
        };
    }

    /// The numeric value, parsing strings; null if not numeric.
    pub fn number(v: CtxValue) ?f64 {
        return switch (v) {
            .num => |n| n,
            .str => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    fn eql(a: CtxValue, b: CtxValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .undef => true,
            .bool => |x| x == b.bool,
            .num => |x| x == b.num,
            .str => |x| std.mem.eql(u8, x, b.str),
            .list => |x| x.len == b.list.len and for (x, b.list) |p, q| {
                if (!std.mem.eql(u8, p, q)) break false;
            } else true,
        };
    }
};

/// Interned id of a global context key.
pub const KeyId = enum(u32) { _ };

/// One frame of the focus chain (mirrors E04 `KeyContext`): its `name` is a
/// boolean key set to true (e.g. `Editor`, `Terminal`) and its `attrs` are
/// string keys (e.g. `vim.mode = "normal"`). The E04 adapter converts its
/// type to this one without copying.
pub const KeyContext = struct {
    name: []const u8,
    attrs: []const Attr = &.{},

    /// A string attribute.
    pub const Attr = struct { key: []const u8, value: []const u8 };
};

/// The environment a when-clause evaluates against.
pub const EvalEnv = struct {
    global: *const ContextKeyService,
    /// Innermost last.
    stack: []const KeyContext = &.{},
    /// For `config.<setting>` keys.
    settings: ?*const store.Snapshot = null,

    /// Looks `name` up: the context stack innermost first, then global keys,
    /// then `config.*` in the settings snapshot.
    pub fn lookup(env: *const EvalEnv, name: []const u8, id: ?KeyId) CtxValue {
        var i = env.stack.len;
        while (i > 0) {
            i -= 1;
            const c = env.stack[i];
            for (c.attrs) |a| if (std.mem.eql(u8, a.key, name)) return .{ .str = a.value };
            if (std.mem.eql(u8, c.name, name)) return .{ .bool = true };
        }
        if (id) |k| {
            const v = env.global.get(k);
            if (v != .undef) return v;
        }
        return .undef;
    }

    /// The value of setting `key` as a context value.
    pub fn config(env: *const EvalEnv, key: []const u8) CtxValue {
        const snap = env.settings orelse return .undef;
        const v = snap.getByKey(key, .{}) orelse return .undef;
        return switch (v) {
            .bool => |b| .{ .bool = b },
            .int => |n| .{ .num = @floatFromInt(n) },
            .float => |f| .{ .num = f },
            .string, .enum_lit => |s| .{ .str = s },
            else => .undef,
        };
    }
};

/// The global context keys. Owners set keys on the UI thread; `generation`
/// bumps on every effective change so caches (keybinding labels) know when
/// to recompute.
pub const ContextKeyService = struct {
    gpa: Allocator,
    ids: std.StringHashMapUnmanaged(KeyId) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(CtxValue) = .empty,
    gen: u64 = 0,

    /// An empty service.
    pub fn init(gpa: Allocator) ContextKeyService {
        return .{ .gpa = gpa };
    }

    /// Frees all keys and values.
    pub fn deinit(s: *ContextKeyService) void {
        for (s.values.items) |v| s.freeValue(v);
        for (s.names.items) |n| s.gpa.free(n);
        s.values.deinit(s.gpa);
        s.names.deinit(s.gpa);
        s.ids.deinit(s.gpa);
    }

    /// Interns `name`.
    pub fn key(s: *ContextKeyService, key_name: []const u8) error{OutOfMemory}!KeyId {
        if (s.ids.get(key_name)) |id| return id;
        const owned = try s.gpa.dupe(u8, key_name);
        errdefer s.gpa.free(owned);
        const id: KeyId = @enumFromInt(s.names.items.len);
        try s.names.append(s.gpa, owned);
        errdefer _ = s.names.pop();
        try s.values.append(s.gpa, .undef);
        errdefer _ = s.values.pop();
        try s.ids.put(s.gpa, owned, id);
        return id;
    }

    /// The id of `name` if interned.
    pub fn find(s: *const ContextKeyService, key_name: []const u8) ?KeyId {
        return s.ids.get(key_name);
    }

    /// The name of `k`.
    pub fn name(s: *const ContextKeyService, k: KeyId) []const u8 {
        return s.names.items[@intFromEnum(k)];
    }

    /// Sets `k` (copies strings). UI thread. Bumps the generation if changed.
    pub fn set(s: *ContextKeyService, k: KeyId, v: CtxValue) error{OutOfMemory}!void {
        const slot = &s.values.items[@intFromEnum(k)];
        if (slot.eql(v)) return;
        const copy = try s.dupeValue(v);
        s.freeValue(slot.*);
        slot.* = copy;
        s.gen += 1;
    }

    /// Interns `name` and sets it.
    pub fn setByName(s: *ContextKeyService, n: []const u8, v: CtxValue) error{OutOfMemory}!void {
        try s.set(try s.key(n), v);
    }

    /// The value of `k`.
    pub fn get(s: *const ContextKeyService, k: KeyId) CtxValue {
        return s.values.items[@intFromEnum(k)];
    }

    /// Bumps on every effective change.
    pub fn generation(s: *const ContextKeyService) u64 {
        return s.gen;
    }

    fn dupeValue(s: *ContextKeyService, v: CtxValue) error{OutOfMemory}!CtxValue {
        return switch (v) {
            .str => |x| .{ .str = try s.gpa.dupe(u8, x) },
            .list => |xs| blk: {
                const out = try s.gpa.alloc([]const u8, xs.len);
                var n: usize = 0;
                errdefer {
                    for (out[0..n]) |o| s.gpa.free(o);
                    s.gpa.free(out);
                }
                for (xs) |x| {
                    out[n] = try s.gpa.dupe(u8, x);
                    n += 1;
                }
                break :blk .{ .list = out };
            },
            else => v,
        };
    }

    fn freeValue(s: *ContextKeyService, v: CtxValue) void {
        switch (v) {
            .str => |x| s.gpa.free(x),
            .list => |xs| {
                for (xs) |x| s.gpa.free(x);
                s.gpa.free(xs);
            },
            else => {},
        }
    }
};

/// Standard global keys with the epic that sets each one. Documented in
/// `packages/config/docs/context-keys.md`.
pub const standard_keys = [_]struct { name: []const u8, owner: []const u8, doc: []const u8 }{
    .{ .name = "editorTextFocus", .owner = "E05", .doc = "An editor text area has keyboard focus" },
    .{ .name = "editorFocus", .owner = "E05", .doc = "An editor (text or its widgets) has focus" },
    .{ .name = "editorReadonly", .owner = "E05", .doc = "The focused editor is read-only" },
    .{ .name = "editorLangId", .owner = "E05", .doc = "Language id of the focused editor" },
    .{ .name = "editorHasSelection", .owner = "E05", .doc = "The focused editor has a non-empty selection" },
    .{ .name = "editorHasMultipleSelections", .owner = "E05", .doc = "The focused editor has several cursors" },
    .{ .name = "textInputFocus", .owner = "E04", .doc = "Any text input (editor or field) has focus" },
    .{ .name = "inputFocus", .owner = "E04", .doc = "Any input widget has focus" },
    .{ .name = "terminalFocus", .owner = "E06", .doc = "A terminal has focus" },
    .{ .name = "terminal.altScreen", .owner = "E06", .doc = "The focused terminal shows the alternate screen" },
    .{ .name = "sideBarVisible", .owner = "E04", .doc = "The side bar is visible" },
    .{ .name = "panelVisible", .owner = "E04", .doc = "The bottom panel is visible" },
    .{ .name = "activePanel", .owner = "E04", .doc = "Id of the active panel" },
    .{ .name = "activeViewlet", .owner = "E04", .doc = "Id of the active side bar view" },
    .{ .name = "resourceScheme", .owner = "E08", .doc = "URI scheme of the active resource" },
    .{ .name = "resourceFilename", .owner = "E08", .doc = "File name of the active resource" },
    .{ .name = "resourceExtname", .owner = "E08", .doc = "Extension of the active resource, with the dot" },
    .{ .name = "resourceLangId", .owner = "E08", .doc = "Language id of the active resource" },
    .{ .name = "isLinux", .owner = "E15", .doc = "Running on Linux" },
    .{ .name = "isWindows", .owner = "E15", .doc = "Running on Windows" },
    .{ .name = "isMac", .owner = "E15", .doc = "Running on macOS" },
    .{ .name = "inQuickOpen", .owner = "E04", .doc = "A quick pick (palette) is open" },
    .{ .name = "inDebugMode", .owner = "E07", .doc = "A debug session is active" },
    .{ .name = "agentFocus", .owner = "E10", .doc = "The agent panel has focus" },
    .{ .name = "agentRunning", .owner = "E10", .doc = "An agent turn is running" },
    .{ .name = "agentAwaitingApproval", .owner = "E10", .doc = "An agent waits for a permission decision" },
    .{ .name = "reviewQueueNonEmpty", .owner = "E12", .doc = "The review queue has pending changesets" },
    .{ .name = "suggestWidgetVisible", .owner = "E05", .doc = "The completion list is visible" },
    .{ .name = "ghostVisible", .owner = "E10", .doc = "Inline AI ghost text is visible" },
    .{ .name = "inSnippetMode", .owner = "E05", .doc = "A snippet session is active" },
    .{ .name = "scm.hasChanges", .owner = "E09", .doc = "The repository has uncommitted changes" },
    .{ .name = "workspaceTrusted", .owner = "E16", .doc = "The workspace is trusted" },
};

/// Interns every standard key and sets the platform keys for `os`.
pub fn registerStandard(s: *ContextKeyService, os: std.Target.Os.Tag) error{OutOfMemory}!void {
    for (standard_keys) |k| _ = try s.key(k.name);
    try s.setByName("isLinux", .{ .bool = os == .linux });
    try s.setByName("isWindows", .{ .bool = os == .windows });
    try s.setByName("isMac", .{ .bool = os == .macos });
}

test "context: set, generation and ownership" {
    var s = ContextKeyService.init(std.testing.allocator);
    defer s.deinit();
    try registerStandard(&s, .linux);
    const g0 = s.generation();
    const k = try s.key("resourceLangId");
    var buf = "zig".*;
    try s.set(k, .{ .str = &buf });
    buf[0] = 'x';
    try std.testing.expectEqualStrings("zig", s.get(k).str);
    try s.set(k, .{ .str = "zig" });
    try std.testing.expectEqual(g0 + 1, s.generation());
    try s.set(k, .{ .list = &.{ "a", "b" } });
    try std.testing.expect(s.get(try s.key("isLinux")).bool);
    try std.testing.expect(!s.get(try s.key("isWindows")).bool);
}

test "context: stack lookup innermost wins, attrs" {
    var s = ContextKeyService.init(std.testing.allocator);
    defer s.deinit();
    const k = try s.key("vim.mode");
    try s.set(k, .{ .str = "global" });
    const stack = [_]KeyContext{
        .{ .name = "Workbench", .attrs = &.{.{ .key = "vim.mode", .value = "insert" }} },
        .{ .name = "Editor", .attrs = &.{.{ .key = "vim.mode", .value = "normal" }} },
    };
    const env: EvalEnv = .{ .global = &s, .stack = &stack };
    try std.testing.expectEqualStrings("normal", env.lookup("vim.mode", k).str);
    try std.testing.expect(env.lookup("Editor", null).bool);
    try std.testing.expect(env.lookup("Terminal", null) == .undef);
    const env2: EvalEnv = .{ .global = &s };
    try std.testing.expectEqualStrings("global", env2.lookup("vim.mode", k).str);
}
