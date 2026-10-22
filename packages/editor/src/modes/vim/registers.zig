//! Vim registers (change.txt, "Registers"): the unnamed register, `0`
//! for the last yank, `1`-`9` shifting on deletes that span lines, `-` for
//! small deletes, `a`-`z` (`A`-`Z` append), the black hole `_`, `+` and
//! `*` on the system clipboard and primary selection, and the read-only
//! `.`, `:` and `/`.

const std = @import("std");
const ops = @import("operators.zig");

const Allocator = std.mem.Allocator;
pub const Register = ops.Register;
pub const RegKind = ops.RegKind;

/// The system clipboard (`+`) and primary selection (`*`), supplied by
/// the platform (E01). Without one, `+` and `*` are ordinary registers.
pub const ClipboardPort = struct {
    pub const Which = enum { clipboard, primary };

    ctx: *anyopaque,
    /// The current text (caller frees), or null when empty.
    getFn: *const fn (ctx: *anyopaque, which: Which, gpa: Allocator) anyerror!?[]u8,
    setFn: *const fn (ctx: *anyopaque, which: Which, text: []const u8) anyerror!void,
};

/// What wrote a register, for Vim's choice of numbered registers.
pub const Op = enum { yank, delete };

const slot_count = 42;

fn slotOf(name: u8) ?usize {
    return switch (name) {
        'a'...'z' => name - 'a',
        'A'...'Z' => name - 'A',
        '0'...'9' => 26 + @as(usize, name - '0'),
        '-' => 36,
        '+' => 37,
        '*' => 38,
        '.' => 39,
        ':' => 40,
        '/' => 41,
        else => null,
    };
}

pub const Registers = struct {
    gpa: Allocator,
    slots: [slot_count]Register = @splat(.{}),
    /// The slot the unnamed register `"` points at.
    unnamed: usize = 26,
    clipboard: ?ClipboardPort = null,

    pub fn init(gpa: Allocator) Registers {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Registers) void {
        for (&r.slots) |*s| s.deinit(r.gpa);
    }

    /// Whether `name` is a register (for `"x`).
    pub fn valid(name: u8) bool {
        return name == '"' or name == '_' or slotOf(name) != null;
    }

    /// Register `name`, or null for `_`, an unknown name or an empty
    /// register. `+` and `*` read the platform clipboard.
    pub fn get(r: *Registers, name: u8) ?*const Register {
        const i = if (name == '"') r.unnamed else slotOf(name) orelse return null;
        if (i == 37 or i == 38) r.refreshClipboard(i);
        const reg = &r.slots[i];
        return if (reg.pieceCount() == 0) null else reg;
    }

    /// Sets register `name` to `text` (`A`-`Z` append). Read-only and
    /// unknown names are ignored, like the black hole.
    pub fn put(r: *Registers, name: u8, text: []const u8, kind: RegKind) !void {
        var tmp: Register = .{ .kind = kind };
        defer tmp.deinit(r.gpa);
        try tmp.prepend(r.gpa, text);
        try r.write(name, &tmp);
    }

    /// Stores the text an operator yanked or deleted, following Vim: a
    /// yank goes to `0` (or the named register); a delete goes to the named
    /// register and, when it spans lines or `use_one` (the `%`, `(`, `)`,
    /// `` ` ``, `/`, `?`, `n`, `N`, `{`, `}` motions), shifts `1`-`9` and
    /// goes to `1`; a delete within one line without a name goes to `-`
    /// (as well as to `1` for those motions). The unnamed
    /// register then points at the last one written.
    pub fn record(r: *Registers, name: ?u8, op: Op, value: *const Register, use_one: bool) !void {
        if (name == '_') return;
        if (name) |n| if (n != '"') {
            const i = slotOf(n) orelse return;
            if (i >= 39) return;
        };
        const named: ?u8 = if (name == null or name.? == '"') null else name;
        if (op == .yank) {
            try r.write(named orelse '0', value);
            return;
        }
        if (named) |n| try r.write(n, value);
        var multi = value.kind == .linewise;
        for (0..value.pieceCount()) |k| {
            if (std.mem.indexOfScalar(u8, value.piece(k), '\n') != null) multi = true;
        }
        if (multi or use_one) {
            r.shiftNumbered();
            try r.assign(27, value);
            if (named == null or !std.ascii.isUpper(named.?)) r.unnamed = 27;
        }
        // Within one line, an unnamed delete also goes to "- (even when
        // the motion put it in "1 as well).
        if (!multi and named == null) {
            try r.assign(36, value);
            r.unnamed = 36;
        }
    }

    /// Sets a read-only register (`.` inserted text, `:` last command
    /// line, `/` last search).
    pub fn setReadOnly(r: *Registers, name: u8, text: []const u8) !void {
        const i = slotOf(name).?;
        r.slots[i].clear(.charwise);
        try r.slots[i].prepend(r.gpa, text);
    }

    fn write(r: *Registers, name: u8, value: *const Register) !void {
        if (name == '_') return;
        if (name == '"') return r.write('0', value);
        const i = slotOf(name) orelse return;
        if (i >= 39) return;
        if (std.ascii.isUpper(name) and r.slots[i].pieceCount() > 0) {
            try r.append(i, value);
        } else try r.assign(i, value);
        r.unnamed = i;
        if (i == 37 or i == 38) try r.pushClipboard(i);
    }

    fn assign(r: *Registers, i: usize, value: *const Register) !void {
        const dst = &r.slots[i];
        dst.clear(value.kind);
        try dst.text.appendSlice(r.gpa, value.text.items);
        try dst.ends.appendSlice(r.gpa, value.ends.items);
    }

    /// `"Ay`: charwise onto charwise joins the text; anything linewise
    /// makes a linewise register of whole lines.
    fn append(r: *Registers, i: usize, value: *const Register) !void {
        const dst = &r.slots[i];
        const old = try dst.joined(r.gpa);
        defer r.gpa.free(old);
        const new = try value.joined(r.gpa);
        defer r.gpa.free(new);
        const linewise = dst.kind == .linewise or value.kind == .linewise;
        dst.clear(if (linewise) .linewise else dst.kind);
        try dst.text.appendSlice(r.gpa, old);
        if (linewise and old.len > 0 and old[old.len - 1] != '\n') try dst.text.append(r.gpa, '\n');
        try dst.text.appendSlice(r.gpa, new);
        if (linewise and new.len > 0 and new[new.len - 1] != '\n') try dst.text.append(r.gpa, '\n');
        try dst.ends.append(r.gpa, @intCast(dst.text.items.len));
    }

    fn shiftNumbered(r: *Registers) void {
        // 9 falls off; 1-8 move up; 1 is then written.
        var nine = r.slots[35];
        nine.deinit(r.gpa);
        var k: usize = 35;
        while (k > 27) : (k -= 1) r.slots[k] = r.slots[k - 1];
        r.slots[27] = .{};
    }

    fn which(i: usize) ClipboardPort.Which {
        return if (i == 37) .clipboard else .primary;
    }

    fn pushClipboard(r: *Registers, i: usize) !void {
        const cb = r.clipboard orelse return;
        const text = try r.slots[i].joined(r.gpa);
        defer r.gpa.free(text);
        cb.setFn(cb.ctx, which(i), text) catch {};
    }

    /// Reads the platform clipboard into slot `i`, keeping the register's
    /// own type when the text is still what Vim put there.
    fn refreshClipboard(r: *Registers, i: usize) void {
        const cb = r.clipboard orelse return;
        const text = (cb.getFn(cb.ctx, which(i), r.gpa) catch return) orelse {
            r.slots[i].clear(.charwise);
            return;
        };
        defer r.gpa.free(text);
        const mine = r.slots[i].joined(r.gpa) catch return;
        defer r.gpa.free(mine);
        if (std.mem.eql(u8, mine, text)) return;
        const kind: RegKind = if (text.len > 0 and text[text.len - 1] == '\n') .linewise else .charwise;
        r.slots[i].clear(kind);
        r.slots[i].prepend(r.gpa, text) catch {};
    }
};

fn expectReg(r: *Registers, name: u8, want: ?[]const u8) !void {
    const gpa = std.testing.allocator;
    const reg = r.get(name) orelse {
        try std.testing.expect(want == null);
        return;
    };
    const t = try reg.joined(gpa);
    defer gpa.free(t);
    try std.testing.expectEqualStrings(want.?, t);
}

fn val(kind: RegKind, text: []const u8) !Register {
    var v: Register = .{ .kind = kind };
    try v.prepend(std.testing.allocator, text);
    return v;
}

test "vim: registers" {
    const gpa = std.testing.allocator;
    var r: Registers = .init(gpa);
    defer r.deinit();

    // Yanks go to 0 and the unnamed register.
    var y = try val(.charwise, "yank");
    defer y.deinit(gpa);
    try r.record(null, .yank, &y, false);
    try expectReg(&r, '0', "yank");
    try expectReg(&r, '"', "yank");

    // Small deletes go to "-"; line deletes shift 1-9.
    var small = try val(.charwise, "w");
    defer small.deinit(gpa);
    try r.record(null, .delete, &small, false);
    try expectReg(&r, '-', "w");
    try expectReg(&r, '"', "w");
    try expectReg(&r, '1', null);
    for ([_][]const u8{ "l1\n", "l2\n", "l3\n" }) |t| {
        var d = try val(.linewise, t);
        defer d.deinit(gpa);
        try r.record(null, .delete, &d, false);
    }
    try expectReg(&r, '1', "l3\n");
    try expectReg(&r, '2', "l2\n");
    try expectReg(&r, '3', "l1\n");
    try expectReg(&r, '"', "l3\n");
    try expectReg(&r, '0', "yank");
    // A charwise delete over a line break, or with %, also shifts.
    var over = try val(.charwise, "a\nb");
    defer over.deinit(gpa);
    try r.record(null, .delete, &over, false);
    try expectReg(&r, '1', "a\nb");
    try expectReg(&r, '4', "l1\n");
    try r.record(null, .delete, &small, true);
    try expectReg(&r, '1', "w");
    for (0..10) |_| try r.record(null, .delete, &over, false);
    try expectReg(&r, '9', "a\nb");

    // Named registers, appending, the black hole.
    var a = try val(.charwise, "one");
    defer a.deinit(gpa);
    try r.record('a', .yank, &a, false);
    try expectReg(&r, '"', "one");
    try expectReg(&r, '0', "yank");
    try r.record('A', .yank, &a, false);
    try expectReg(&r, 'a', "oneone");
    var line = try val(.linewise, "L\n");
    defer line.deinit(gpa);
    try r.record('A', .yank, &line, false);
    try expectReg(&r, 'a', "oneone\nL\n");
    try std.testing.expectEqual(RegKind.linewise, r.get('a').?.kind);
    try r.record('_', .delete, &line, false);
    try expectReg(&r, '"', "oneone\nL\n");
    try r.put('b', "set", .charwise);
    try expectReg(&r, 'b', "set");
    try r.put('.', "ignored", .charwise);
    try expectReg(&r, '.', null);
    try r.setReadOnly('.', "typed");
    try expectReg(&r, '.', "typed");
}

const FakeClip = struct {
    text: [2]std.ArrayList(u8) = .{ .empty, .empty },

    fn get(ctx: *anyopaque, which: ClipboardPort.Which, gpa: Allocator) anyerror!?[]u8 {
        const f: *FakeClip = @ptrCast(@alignCast(ctx));
        const t = f.text[@intFromEnum(which)].items;
        return if (t.len == 0) null else try gpa.dupe(u8, t);
    }

    fn set(ctx: *anyopaque, which: ClipboardPort.Which, text: []const u8) anyerror!void {
        const f: *FakeClip = @ptrCast(@alignCast(ctx));
        const l = &f.text[@intFromEnum(which)];
        l.clearRetainingCapacity();
        try l.appendSlice(std.testing.allocator, text);
    }
};

test "vim: registers on the clipboard" {
    const gpa = std.testing.allocator;
    var fake: FakeClip = .{};
    defer for (&fake.text) |*t| t.deinit(gpa);
    var r: Registers = .init(gpa);
    defer r.deinit();
    r.clipboard = .{ .ctx = &fake, .getFn = FakeClip.get, .setFn = FakeClip.set };
    var v = try val(.linewise, "x\n");
    defer v.deinit(gpa);
    try r.record('+', .yank, &v, false);
    try std.testing.expectEqualStrings("x\n", fake.text[0].items);
    try std.testing.expectEqual(RegKind.linewise, r.get('+').?.kind);
    // Text another program put there.
    try FakeClip.set(&fake, .primary, "from outside");
    try expectReg(&r, '*', "from outside");
    try std.testing.expectEqual(RegKind.charwise, r.get('*').?.kind);
}
