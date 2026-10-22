//! Lexer states. A lexer works on a mutable `LexState` while it scans a
//! line; at the line end the state is interned into a `StateTable`, so the
//! "did this line's end state change?" test that drives incremental
//! relexing is one integer comparison.

const std = @import("std");
const LanguageId = @import("../language.zig").LanguageId;

const Allocator = std.mem.Allocator;

/// An interned lexer state. `initial` is the root language's start state;
/// `unknown` marks lines never lexed and equals no real state.
pub const StateId = enum(u32) { initial = 0, unknown = std.math.maxInt(u32), _ };

/// A suspended (or the running) language on the injection stack.
pub const Frame = struct {
    lang: LanguageId,
    /// The host's `mode` while a guest runs; 0 for the top frame.
    mode: u16 = 0,
    /// The host's `depth` while a guest runs; 0 for the top frame.
    depth: u16 = 0,
};

/// The state at a line boundary. `mode`, `depth` and `aux` belong to the
/// top language and mean whatever it wants (comment depth, string
/// delimiter, heredoc tag bytes, template brace stack).
pub const LexState = struct {
    pub const max_stack = 4;
    pub const max_aux = 32;

    stack: [max_stack]Frame,
    stack_len: u8 = 1,
    mode: u16 = 0,
    depth: u16 = 0,
    aux: [max_aux]u8 = @splat(0),
    aux_len: u8 = 0,

    /// The start state of a document in `lang`.
    pub fn init(lang: LanguageId) LexState {
        var s: LexState = .{ .stack = undefined };
        s.stack = @splat(.{ .lang = lang });
        return s;
    }

    /// The running language.
    pub fn top(s: *const LexState) LanguageId {
        return s.stack[s.stack_len - 1].lang;
    }

    /// Whether a guest language is running.
    pub fn injected(s: *const LexState) bool {
        return s.stack_len > 1;
    }

    /// Suspends the running language and starts `guest` in its initial
    /// mode. Returns false (and changes nothing) when the stack is full.
    pub fn push(s: *LexState, guest: LanguageId) bool {
        if (s.stack_len == max_stack) return false;
        s.stack[s.stack_len - 1].mode = s.mode;
        s.stack[s.stack_len - 1].depth = s.depth;
        s.stack[s.stack_len] = .{ .lang = guest };
        s.stack_len += 1;
        s.mode = 0;
        s.depth = 0;
        s.clearAux();
        return true;
    }

    /// Ends the running guest and resumes its host's mode and depth (the
    /// host's aux bytes are not kept). No-op at the root.
    pub fn pop(s: *LexState) void {
        if (s.stack_len == 1) return;
        s.stack_len -= 1;
        const f = &s.stack[s.stack_len - 1];
        s.mode = f.mode;
        s.depth = f.depth;
        f.mode = 0;
        f.depth = 0;
        s.clearAux();
    }

    /// The aux bytes.
    pub fn auxBytes(s: *const LexState) []const u8 {
        return s.aux[0..s.aux_len];
    }

    /// Replaces the aux bytes (truncated to `max_aux`).
    pub fn setAux(s: *LexState, bytes: []const u8) void {
        s.clearAux();
        const n = @min(bytes.len, max_aux);
        @memcpy(s.aux[0..n], bytes[0..n]);
        s.aux_len = @intCast(n);
    }

    /// Clears the aux bytes.
    pub fn clearAux(s: *LexState) void {
        @memset(&s.aux, 0);
        s.aux_len = 0;
    }

    /// Field-wise equality (unused stack slots and aux bytes are ignored).
    pub fn eql(a: *const LexState, b: *const LexState) bool {
        if (a.stack_len != b.stack_len or a.mode != b.mode or a.depth != b.depth) return false;
        for (a.stack[0..a.stack_len], b.stack[0..b.stack_len]) |x, y| {
            if (x.lang != y.lang or x.mode != y.mode or x.depth != y.depth) return false;
        }
        return std.mem.eql(u8, a.auxBytes(), b.auxBytes());
    }

    fn hash(s: *const LexState) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(&.{ s.stack_len, s.aux_len });
        h.update(std.mem.asBytes(&s.mode));
        h.update(std.mem.asBytes(&s.depth));
        for (s.stack[0..s.stack_len]) |f| {
            h.update(std.mem.asBytes(&f.lang));
            h.update(std.mem.asBytes(&f.mode));
            h.update(std.mem.asBytes(&f.depth));
        }
        h.update(s.auxBytes());
        return h.final();
    }
};

/// Interned states of one document. Ids are dense; `initial` is the first.
pub const StateTable = struct {
    /// Most distinct states kept before `intern` reports `error.StateTableFull`
    /// (pathological heredoc tags); the highlighter then resets and relexes.
    pub const max_states = 1 << 16;

    states: std.ArrayList(LexState) = .empty,
    map: std.HashMapUnmanaged(StateId, void, Ctx, 80) = .empty,

    const Ctx = struct {
        t: *const StateTable,
        pub fn hash(c: Ctx, id: StateId) u64 {
            return c.t.get(id).hash();
        }
        pub fn eql(_: Ctx, a: StateId, b: StateId) bool {
            return a == b;
        }
    };

    const Adapter = struct {
        t: *const StateTable,
        pub fn hash(_: Adapter, s: *const LexState) u64 {
            return s.hash();
        }
        pub fn eql(a: Adapter, s: *const LexState, id: StateId) bool {
            return s.eql(a.t.get(id));
        }
    };

    /// A table whose `initial` state is `LexState.init(root)`.
    pub fn init(gpa: Allocator, root: LanguageId) Allocator.Error!StateTable {
        var t: StateTable = .{};
        errdefer t.deinit(gpa);
        const s = LexState.init(root);
        _ = t.intern(gpa, &s) catch |e| switch (e) {
            error.StateTableFull => unreachable,
            else => |x| return x,
        };
        return t;
    }

    /// Frees the table.
    pub fn deinit(t: *StateTable, gpa: Allocator) void {
        t.states.deinit(gpa);
        t.map.deinit(gpa);
    }

    /// Number of distinct states.
    pub fn count(t: *const StateTable) usize {
        return t.states.items.len;
    }

    /// The id of `s`, adding it on first sight.
    pub fn intern(t: *StateTable, gpa: Allocator, s: *const LexState) error{ OutOfMemory, StateTableFull }!StateId {
        const gop = try t.map.getOrPutContextAdapted(gpa, s, Adapter{ .t = t }, Ctx{ .t = t });
        if (gop.found_existing) return gop.key_ptr.*;
        if (t.states.items.len >= max_states) {
            t.map.removeByPtr(gop.key_ptr);
            return error.StateTableFull;
        }
        errdefer t.map.removeByPtr(gop.key_ptr);
        const id: StateId = @enumFromInt(t.states.items.len);
        try t.states.append(gpa, s.*);
        gop.key_ptr.* = id;
        return id;
    }

    /// The state with id `id`.
    pub fn get(t: *const StateTable, id: StateId) *const LexState {
        return &t.states.items[@intFromEnum(id)];
    }

    /// Drops every state except `initial`.
    pub fn reset(t: *StateTable) void {
        t.states.shrinkRetainingCapacity(1);
        t.map.clearRetainingCapacity();
        t.map.putAssumeCapacityContext(.initial, {}, Ctx{ .t = t });
    }
};

test "state: interning equality and cap reset" {
    const gpa = std.testing.allocator;
    const root: LanguageId = @enumFromInt(1);
    var t: StateTable = try .init(gpa, root);
    defer t.deinit(gpa);

    var s = LexState.init(root);
    try std.testing.expectEqual(StateId.initial, try t.intern(gpa, &s));
    s.mode = 3;
    const a = try t.intern(gpa, &s);
    try std.testing.expect(a != .initial);
    s.setAux("EOF");
    const b = try t.intern(gpa, &s);
    try std.testing.expect(b != a);
    // Same fields, built another way: same id.
    var s2 = LexState.init(root);
    s2.setAux("longer tag");
    s2.setAux("EOF");
    s2.mode = 3;
    try std.testing.expectEqual(b, try t.intern(gpa, &s2));

    // Push and pop keep the host's mode; the guest frame is part of the key.
    var s3 = LexState.init(root);
    s3.mode = 7;
    try std.testing.expect(s3.push(@enumFromInt(2)));
    try std.testing.expectEqual(@as(u16, 0), s3.mode);
    const g = try t.intern(gpa, &s3);
    try std.testing.expect(g != .initial and g != a and g != b);
    s3.pop();
    try std.testing.expectEqual(@as(u16, 7), s3.mode);
    try std.testing.expect(!s3.injected());

    // The cap: fill up, then the next new state is refused.
    var i: u16 = 0;
    while (t.count() < StateTable.max_states) : (i += 1) {
        var x = LexState.init(root);
        x.depth = i;
        x.mode = 100;
        _ = try t.intern(gpa, &x);
    }
    var y = LexState.init(root);
    y.mode = 101;
    try std.testing.expectError(error.StateTableFull, t.intern(gpa, &y));
    // Existing states still resolve.
    try std.testing.expectEqual(b, try t.intern(gpa, &s2));
    t.reset();
    try std.testing.expectEqual(@as(usize, 1), t.count());
    try std.testing.expect((try t.intern(gpa, &y)) != .initial);
    var z = LexState.init(root);
    try std.testing.expectEqual(StateId.initial, try t.intern(gpa, &z));
}
