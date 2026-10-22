//! The VT parser: Paul Williams' DEC ANSI state machine (`table.zig`) with a
//! SIMD ground-state fast path (`fast_path.zig`) and a streaming UTF-8
//! decoder (`utf8.zig`).
//!
//! The handler is comptime duck-typed (a pointer to any type with the methods
//! below), so dispatch inlines and the hot path has no vtable:
//!
//! ```zig
//! printAscii(h, run: []const u8)            // 0x20..0x7E only
//! printCodepoints(h, cps: []const u21)      // decoded text, U+FFFD for invalid
//! execute(h, c: u8)                         // C0 (and C1 when enabled)
//! escDispatch(h, e: Esc)
//! csiDispatch(h, c: *const Csi)
//! oscDispatch(h, data: []const u8, term: StringTerm)
//! dcsHook(h, c: *const Csi) bool            // false → payload is discarded
//! dcsPut(h, bytes: []const u8)              // ≤ 4 KiB slices
//! dcsUnhook(h)
//! apcStart(h) bool                          // false → payload is discarded
//! apcPut(h, bytes: []const u8)
//! apcEnd(h)
//! ```
//!
//! `feed` never fails and never allocates after warm-up: the OSC buffer is
//! retained across sequences and grows only up to its cap. Strings over their
//! cap are discarded (OSC) or ended early (DCS, APC).
//!
//! Behaviour on string termination: BEL or ST end an OSC; ESC followed by
//! anything other than '\' also ends it (xterm), and that byte is then
//! processed in the escape state. CAN and SUB abort an OSC without
//! dispatching; DCS and APC handlers still get their unhook/end call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const params = @import("params.zig");
const tables = @import("table.zig");
const fast_path = @import("fast_path.zig");
const utf8 = @import("utf8.zig");

pub const Csi = params.Csi;
pub const Esc = params.Esc;
pub const StringTerm = params.StringTerm;
pub const State = tables.State;

const Parser = @This();

/// Parser limits and modes.
pub const Options = struct {
    /// Maximum OSC payload; longer strings are discarded.
    osc_max: u32 = 64 * 1024,
    /// Maximum payload of an OSC 52 (clipboard) string.
    osc52_max: u32 = 8 * 1024 * 1024,
    /// Maximum total DCS payload; the handler is unhooked at the cap.
    dcs_max: u32 = 1 * 1024 * 1024,
    /// Maximum total APC payload; the handler is ended at the cap.
    apc_max: u32 = 64 * 1024 * 1024,
    /// Recognise 8-bit C1 controls (0x80-0x9F). Off in UTF-8 mode.
    c1_8bit: bool = false,
};

/// Largest slice passed to `dcsPut` / `apcPut`.
pub const put_slice_max = 4096;

const StringKind = enum { sos, pm, apc };

gpa: Allocator,
opts: Options,
state: State = .ground,
csi: Csi = .{},
/// More than two intermediates were collected; the sequence is ignored.
inter_overflow: bool = false,
decoder: utf8.Decoder = .{},
osc: std.ArrayList(u8) = .empty,
osc_overflow: bool = false,
string_kind: StringKind = .sos,
apc_active: bool = false,
apc_total: usize = 0,
dcs_active: bool = false,
dcs_total: usize = 0,
/// A string was just ended by ESC; a following '\' completes ST silently.
swallow_st: bool = false,

/// Creates a parser. Call `deinit` to free the OSC buffer.
pub fn init(gpa: Allocator, o: Options) Parser {
    return .{ .gpa = gpa, .opts = o, .decoder = .{ .c1_8bit = o.c1_8bit } };
}

/// Frees the OSC buffer.
pub fn deinit(p: *Parser) void {
    p.osc.deinit(p.gpa);
    p.* = undefined;
}

/// Returns to the ground state, dropping any partial sequence. Handlers get
/// no unhook/end calls for strings in progress.
pub fn reset(p: *Parser) void {
    p.state = .ground;
    p.csi = .{};
    p.inter_overflow = false;
    p.decoder.reset();
    p.osc.clearRetainingCapacity();
    p.osc_overflow = false;
    p.apc_active = false;
    p.dcs_active = false;
    p.swallow_st = false;
}

/// Parses `bytes`, calling methods of `h` (a pointer) as sequences complete.
/// Sequences may be split across calls at any byte.
pub fn feed(p: *Parser, bytes: []const u8, h: anytype) void {
    p.feedImpl(true, bytes, h);
}

/// Like `feed`, but every byte goes through the state table one at a time.
/// The reference for the fast-path equivalence fuzz target.
pub fn feedSlow(p: *Parser, bytes: []const u8, h: anytype) void {
    p.feedImpl(false, bytes, h);
}

inline fn feedImpl(p: *Parser, comptime fast: bool, bytes: []const u8, h: anytype) void {
    const tab = if (p.opts.c1_8bit) &tables.table_c1 else &tables.table;
    var i: usize = 0;
    while (i < bytes.len) {
        switch (p.state) {
            .ground => {
                if (fast and !p.decoder.pending()) {
                    const n = fast_path.scanPrintable(bytes[i..]);
                    if (n > 0) {
                        h.printAscii(bytes[i..][0..n]);
                        i += n;
                        continue;
                    }
                }
                const b = bytes[i];
                if (fast and b == 0x1B and i + 1 < bytes.len and bytes[i + 1] == '[' and !p.decoder.pending()) {
                    i += 2 + p.csiFast(bytes[i + 2 ..], h);
                    continue;
                }
                if (p.decoder.pending() or (b >= 0x80 and !(p.opts.c1_8bit and b <= 0x9F))) {
                    var buf: [512]u21 = undefined;
                    const src = if (fast) bytes[i..] else bytes[i..][0..1];
                    const r = p.decoder.decode(src, &buf);
                    if (r.written > 0) h.printCodepoints(buf[0..r.written]);
                    i += r.consumed;
                    if (r.consumed > 0 or r.written > 0) continue;
                }
                p.step(tab, b, h);
                i += 1;
            },
            .osc_string, .dcs_passthrough, .sos_pm_apc_string => {
                if (fast) {
                    const n = p.stringRun(bytes[i..]);
                    if (n > 0) {
                        p.putString(bytes[i..][0..n], h);
                        i += n;
                        continue;
                    }
                }
                p.step(tab, bytes[i], h);
                i += 1;
            },
            else => {
                p.step(tab, bytes[i], h);
                i += 1;
            },
        }
    }
}

/// Fast path for `ESC [` seen in ground: accumulates an optional private
/// marker and parameters inline and dispatches on a final byte. On anything
/// else (an intermediate, a control, the end of input) it leaves the parser in
/// exactly the state the table would have reached (csi_entry or csi_param)
/// and returns, so the table continues from that byte. Returns the number of
/// bytes consumed after `ESC [`.
fn csiFast(p: *Parser, bytes: []const u8, h: anytype) usize {
    p.csi.clear();
    p.inter_overflow = false;
    p.state = .csi_entry;
    var i: usize = 0;
    if (i < bytes.len and bytes[i] >= 0x3C and bytes[i] <= 0x3F) {
        p.csi.private = bytes[i];
        p.state = .csi_param;
        i += 1;
    }
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        switch (b) {
            '0'...'9' => p.csi.digit(b - '0'),
            ';' => p.csi.separator(false),
            ':' => p.csi.separator(true),
            0x40...0x7E => {
                p.csi.final = b;
                p.state = .ground;
                h.csiDispatch(&p.csi);
                return i + 1;
            },
            else => return i,
        }
        p.state = .csi_param;
    }
    return i;
}

/// Length of the leading run of plain data bytes for the current string
/// state (bytes whose table action is `put` without a state change).
fn stringRun(p: *const Parser, bytes: []const u8) usize {
    const c1 = p.opts.c1_8bit;
    for (bytes, 0..) |b, i| {
        const data = switch (p.state) {
            .dcs_passthrough => b != 0x18 and b != 0x1A and b != 0x1B and b != 0x7F,
            else => b >= 0x20,
        };
        if (!data or (c1 and b >= 0x80 and b <= 0x9F)) return i;
    }
    return bytes.len;
}

fn step(p: *Parser, tab: *const [14][256]tables.Transition, b: u8, h: anytype) void {
    if (p.state == .escape and p.swallow_st) {
        p.swallow_st = false;
        if (b == '\\') {
            p.state = .ground;
            return;
        }
    }
    const tr = tab[@intFromEnum(p.state)][b];
    const changes = tr.next != p.state or tr.action == .reenter;
    if (changes) p.exit(b, h);
    p.action(tr.action, b, h);
    if (changes) {
        p.state = tr.next;
        p.entry(b, h);
    }
}

fn action(p: *Parser, a: tables.ActionTag, b: u8, h: anytype) void {
    switch (a) {
        .ignore, .hook, .reenter => {},
        .print => {
            const cp = [1]u21{b};
            h.printCodepoints(&cp);
        },
        .execute => h.execute(b),
        .collect => {
            if (b >= 0x3C and b <= 0x3F) {
                p.csi.private = b;
            } else if (p.csi.inter_len == params.max_intermediates) {
                p.inter_overflow = true;
            } else {
                p.csi.inter[p.csi.inter_len] = b;
                p.csi.inter_len += 1;
            }
        },
        .param => switch (b) {
            '0'...'9' => p.csi.digit(b - '0'),
            ';' => p.csi.separator(false),
            ':' => p.csi.separator(true),
            else => unreachable,
        },
        .esc_dispatch => if (!p.inter_overflow) {
            h.escDispatch(.{ .inter = p.csi.inter, .inter_len = p.csi.inter_len, .final = b });
        },
        .csi_dispatch => if (!p.inter_overflow) {
            p.csi.final = b;
            h.csiDispatch(&p.csi);
        },
        .put => {
            const one = [1]u8{b};
            p.putString(&one, h);
        },
    }
}

fn exit(p: *Parser, b: u8, h: anytype) void {
    const by_esc = b == 0x1B;
    switch (p.state) {
        .osc_string => {
            const terminated = b == 0x07 or by_esc or b == 0x9C;
            if (terminated and !p.osc_overflow) {
                h.oscDispatch(p.osc.items, if (b == 0x07) .bel else .st);
            }
            p.osc.clearRetainingCapacity();
            p.osc_overflow = false;
        },
        .dcs_passthrough => if (p.dcs_active) {
            p.dcs_active = false;
            h.dcsUnhook();
        },
        .sos_pm_apc_string => if (p.apc_active) {
            p.apc_active = false;
            h.apcEnd();
        },
        .dcs_ignore => {},
        else => return,
    }
    if (by_esc) p.swallow_st = true;
}

fn entry(p: *Parser, b: u8, h: anytype) void {
    switch (p.state) {
        .escape, .csi_entry, .dcs_entry => {
            p.csi.clear();
            p.inter_overflow = false;
        },
        .osc_string => {
            p.osc.clearRetainingCapacity();
            p.osc_overflow = false;
        },
        .dcs_passthrough => {
            p.csi.final = b;
            if (!p.inter_overflow and h.dcsHook(&p.csi)) {
                p.dcs_active = true;
                p.dcs_total = 0;
            } else {
                p.state = .dcs_ignore;
            }
        },
        .sos_pm_apc_string => {
            p.string_kind = switch (b) {
                0x58, 0x98 => .sos,
                0x5E, 0x9E => .pm,
                else => .apc,
            };
            p.apc_total = 0;
            p.apc_active = p.string_kind == .apc and h.apcStart();
        },
        else => {},
    }
}

fn putString(p: *Parser, bytes: []const u8, h: anytype) void {
    switch (p.state) {
        .osc_string => p.oscPut(bytes),
        .dcs_passthrough => {
            if (!p.dcs_active) return;
            const room = p.opts.dcs_max - @min(p.dcs_total, p.opts.dcs_max);
            const take = @min(room, bytes.len);
            putSlices(bytes[0..take], h, "dcsPut");
            p.dcs_total += take;
            if (take < bytes.len) {
                p.dcs_active = false;
                h.dcsUnhook();
                p.state = .dcs_ignore;
            }
        },
        .sos_pm_apc_string => {
            if (!p.apc_active) return;
            const room = p.opts.apc_max - @min(p.apc_total, p.opts.apc_max);
            const take = @min(room, bytes.len);
            putSlices(bytes[0..take], h, "apcPut");
            p.apc_total += take;
            if (take < bytes.len) {
                p.apc_active = false;
                h.apcEnd();
            }
        },
        else => unreachable,
    }
}

fn putSlices(bytes: []const u8, h: anytype, comptime method: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, put_slice_max);
        @field(@TypeOf(h.*), method)(h, rest[0..n]);
        rest = rest[n..];
    }
}

fn oscPut(p: *Parser, bytes: []const u8) void {
    if (p.osc_overflow) return;
    const len = p.osc.items.len + bytes.len;
    if (len > p.opts.osc_max) {
        var head: [3]u8 = @splat(0);
        const have = @min(p.osc.items.len, 3);
        @memcpy(head[0..have], p.osc.items[0..have]);
        const more = @min(3 - have, bytes.len);
        @memcpy(head[have..][0..more], bytes[0..more]);
        const is52 = std.mem.eql(u8, &head, "52;");
        if (!is52 or len > p.opts.osc52_max) {
            p.osc_overflow = true;
            p.osc.clearRetainingCapacity();
            return;
        }
    }
    p.osc.appendSlice(p.gpa, bytes) catch {
        p.osc_overflow = true;
        p.osc.clearRetainingCapacity();
    };
}

test {
    _ = @import("Parser_test.zig");
}
