//! Signature help (E07.F03.S01.T03): `onType` asks when a server's
//! trigger character is typed (`(`, `,` ...), and again on its retrigger
//! characters or any other edit while help shows; `invoke` asks from the
//! keyboard (Ctrl+Shift+Space). Each request carries the context
//! (trigger kind and character, whether help already shows and what it
//! shows, with the signature the user cycled to). A null answer, or the
//! caret moving before the opening position or to another line, hides
//! the help.
//!
//! `current` gives the signatures, the active one and the byte range of
//! its active parameter in its label: a parameter label is a substring
//! of the signature label or `[start, end)` offsets in UTF-16 code units
//! of it.

const SignatureService = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");

const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Req = requester.Requester(.@"textDocument/signatureHelp", .signature_help);

pub const State = struct {
    h: DocHandle,
    /// Where help was first asked (just after the trigger character).
    at: u64,
    /// The line of `at`.
    line: u64,
    signatures: []const protocol.SignatureInformation,
    active: u32,
    /// The active parameter of the active signature, if any.
    param: ?u32,
    /// Bytes of the active parameter in `signatures[active].label`.
    param_range: ?[2]usize,

    pub fn signature(s: *const State) *const protocol.SignatureInformation {
        return &s.signatures[s.active];
    }
};

gpa: Allocator,
req: Req,
/// The answer `state` borrows from.
answer: ?*Req.Answer = null,
help: ?protocol.SignatureHelp = null,
state: ?State = null,
/// Where the pending request was asked from.
pending: ?struct { h: DocHandle, at: u64, line: u64 } = null,
/// Bumped when `current` changes.
generation: u64 = 0,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker) SignatureService {
    return .{ .gpa = mgr.gpa, .req = .init(mgr, waker) };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *SignatureService) void {
    s.close();
    s.req.deinit();
}

fn triggers(s: *SignatureService, h: DocHandle, c: u21) struct { trigger: bool, retrigger: bool } {
    var cs: [1]*Client = undefined;
    if (s.req.mgr.clientsFor(h, .signature_help, &cs) == 0) return .{ .trigger = false, .retrigger = false };
    const caps = cs[0].caps() orelse return .{ .trigger = false, .retrigger = false };
    return .{
        .trigger = std.mem.indexOfScalar(u21, caps.signature_triggers, c) != null,
        .retrigger = std.mem.indexOfScalar(u21, caps.signature_retriggers, c) != null,
    };
}

/// `typed` was typed in `h`, leaving the caret at `offset`.
pub fn onType(s: *SignatureService, h: DocHandle, typed: u21, offset: u64) !void {
    const t = s.triggers(h, typed);
    const showing = s.state != null or s.pending != null;
    if (t.trigger or (showing and t.retrigger)) return s.ask(h, offset, .TriggerCharacter, typed);
    if (showing) return s.ask(h, offset, .ContentChange, null);
}

/// Another edit (a deletion, a paste) left the caret at `offset`.
pub fn onEdit(s: *SignatureService, h: DocHandle, offset: u64) !void {
    if (s.state == null and s.pending == null) return;
    if (s.moved(h, offset)) return s.close();
    return s.ask(h, offset, .ContentChange, null);
}

/// Ctrl+Shift+Space.
pub fn invoke(s: *SignatureService, h: DocHandle, offset: u64) !void {
    return s.ask(h, offset, .Invoked, null);
}

/// The caret moved to `offset` of `h` without an edit.
pub fn cursorMoved(s: *SignatureService, h: DocHandle, offset: u64) void {
    if (s.state == null and s.pending == null) return;
    if (s.moved(h, offset)) s.close();
}

fn moved(s: *SignatureService, h: DocHandle, offset: u64) bool {
    const at, const line, const d = if (s.state) |st| .{ st.at, st.line, st.h } else if (s.pending) |p| .{ p.at, p.line, p.h } else return false;
    if (!std.meta.eql(d, h)) return true;
    const doc = s.req.mgr.docs.get(h) orelse return true;
    if (offset > doc.len()) return true;
    return offset < at or doc.tree.lineOf(offset) != line;
}

fn ask(s: *SignatureService, h: DocHandle, offset: u64, kind: protocol.SignatureHelpTriggerKind, typed: ?u21) !void {
    const doc = s.req.mgr.docs.get(h) orelse return;
    var tc: [4]u8 = undefined;
    const showing = s.state != null;
    var active: ?protocol.SignatureHelp = null;
    if (s.help) |hp| if (s.state) |st| {
        active = hp;
        active.?.activeSignature = st.active;
    };
    const ctx: protocol.SignatureHelpContext = .{
        .triggerKind = kind,
        .triggerCharacter = if (typed) |c| tc[0..(std.unicode.utf8Encode(c, &tc) catch 0)] else null,
        .isRetrigger = showing or s.pending != null,
        .activeSignatureHelp = active,
    };
    const n = try s.req.ask(h, offset, .{ .context = ctx });
    if (n == 0) return s.close();
    // A fresh trigger opens where it was typed; a retrigger keeps the
    // opening position.
    if (s.state) |st| {
        s.pending = .{ .h = h, .at = st.at, .line = st.line };
    } else if (s.pending == null) {
        const off = @min(offset, doc.len());
        s.pending = .{ .h = h, .at = off, .line = doc.tree.lineOf(off) };
    }
}

/// Hides the help (Escape, the caret left the call).
pub fn close(s: *SignatureService) void {
    s.req.cancel();
    s.pending = null;
    s.drop();
}

fn drop(s: *SignatureService) void {
    if (s.answer) |a| s.req.free(a);
    s.answer = null;
    s.help = null;
    if (s.state != null) {
        s.state = null;
        s.generation += 1;
    }
}

/// The help to show, if any.
pub fn current(s: *const SignatureService) ?*const State {
    return if (s.state) |*st| st else null;
}

/// Shows the next (`forward`) or previous signature; false when there
/// is only one.
pub fn cycle(s: *SignatureService, forward: bool) bool {
    const st = if (s.state) |*x| x else return false;
    const n: u32 = @intCast(st.signatures.len);
    if (n < 2) return false;
    st.active = if (forward) (st.active + 1) % n else (st.active + n - 1) % n;
    s.setParam(st, null);
    s.generation += 1;
    return true;
}

/// Applies answers; true when `current` changed.
pub fn tick(s: *SignatureService) bool {
    const g = s.generation;
    for (s.req.take()) |a| {
        const p = s.pending orelse break;
        s.pending = null;
        const doc = s.req.mgr.docs.get(a.h);
        const v = switch (a.result) {
            .ok => |o| o.value,
            else => null,
        };
        const help = v orelse {
            s.drop();
            continue;
        };
        if (doc == null or help.signatures.len == 0) {
            s.drop();
            continue;
        }
        const keep_active = if (s.state) |st| st.active else null;
        s.drop();
        s.req.retain(a);
        s.answer = a;
        s.help = help;
        var active = help.activeSignature orelse keep_active orelse 0;
        if (active >= help.signatures.len) active = 0;
        s.state = .{ .h = a.h, .at = p.at, .line = p.line, .signatures = help.signatures, .active = active, .param = null, .param_range = null };
        s.setParam(&s.state.?, help.activeParameter);
        s.generation += 1;
    }
    return s.generation != g;
}

fn setParam(_: *SignatureService, st: *State, help_param: ?u32) void {
    const sig = st.signature();
    const params = sig.parameters orelse &.{};
    st.param = null;
    st.param_range = null;
    const idx = sig.activeParameter orelse help_param orelse 0;
    if (idx >= params.len) return;
    st.param = idx;
    st.param_range = paramRange(sig.label, params[idx].label);
}

/// Bytes of parameter label `p` in signature label `label`.
pub fn paramRange(label: []const u8, p: protocol.ParameterInformationLabel) ?[2]usize {
    switch (p) {
        .string => |sub| {
            if (sub.len == 0) return null;
            // Look after the opening parenthesis first ("f(f: F)").
            const from = if (std.mem.indexOfScalar(u8, label, '(')) |i| i + 1 else 0;
            const i = std.mem.indexOfPos(u8, label, from, sub) orelse std.mem.indexOf(u8, label, sub) orelse return null;
            return .{ i, i + sub.len };
        },
        .tuple => |t| {
            const a = zg_core.utf8.columnToByte(label, t[0], .utf16);
            const b = zg_core.utf8.columnToByte(label, t[1], .utf16);
            if (b <= a) return null;
            return .{ a, b };
        },
    }
}

test "signature: parameter offsets in a UTF-16 label" {
    // "é" is one UTF-16 unit and two bytes; "😀" two units and four bytes.
    const label = "fn é(😀: u8, b: u16)";
    const r = paramRange(label, .{ .tuple = .{ 5, 11 } }).?;
    try std.testing.expectEqualStrings("😀: u8", label[r[0]..r[1]]);
    const r2 = paramRange(label, .{ .string = "b: u16" }).?;
    try std.testing.expectEqualStrings("b: u16", label[r2[0]..r2[1]]);
    // The name before the parenthesis is not the parameter.
    const r3 = paramRange("f(f: F)", .{ .string = "f" }).?;
    try std.testing.expectEqual(@as(usize, 2), r3[0]);
    try std.testing.expect(paramRange(label, .{ .tuple = .{ 3, 3 } }) == null);
    try std.testing.expect(paramRange(label, .{ .string = "zz" }) == null);
}
