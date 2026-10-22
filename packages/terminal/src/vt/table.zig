//! Paul Williams' DEC ANSI parser state diagram, encoded at comptime as a
//! `[14][256]Transition` table.
//!
//! Entry and exit actions are not stored in the table: the parser runs the
//! exit action of the old state and the entry action of the new state
//! whenever `next != state`, or when the action is `reenter` (an "anywhere"
//! transition back into the same state, e.g. ESC ESC).
//!
//! Deviations from the diagram, each documented where it is encoded:
//! - ':' (0x3A) in CSI params is a sub-parameter separator, not csi_ignore.
//! - DEL (0x7F) is ignored in ground (xterm), and is data inside OSC.
//! - BEL (0x07) terminates an OSC string (xterm), in addition to ST.
//! - In UTF-8 mode (`c1_8bit = false`), bytes >= 0x80 are UTF-8 in ground,
//!   data in strings, and abort escape/CSI/DCS headers into the ignore states.
//!
//! Reference: https://vt100.net/emu/dec_ansi_parser

const std = @import("std");

/// Parser states, exactly the 14 of the diagram.
pub const State = enum(u4) {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
};

/// Transition actions. String data (`put`) is routed by the current state.
pub const ActionTag = enum(u4) {
    /// Do nothing.
    ignore,
    /// Print a graphic character (ground; bytes >= 0x80 go to the UTF-8 decoder).
    print,
    /// Execute a C0 or C1 control function.
    execute,
    /// Record a private marker or intermediate byte.
    collect,
    /// Accumulate a parameter digit or separator.
    param,
    /// Dispatch an escape sequence.
    esc_dispatch,
    /// Dispatch a control sequence.
    csi_dispatch,
    /// Final byte of a DCS header: the entry action of dcs_passthrough hooks.
    hook,
    /// String data for OSC, DCS passthrough or APC.
    put,
    /// No action, but run the exit and entry actions even though the state
    /// does not change ("anywhere" transitions into the current state).
    reenter,
};

/// One table entry.
pub const Transition = packed struct(u8) {
    action: ActionTag,
    next: State,
};

/// The table for UTF-8 mode (8-bit C1 controls disabled; the default).
pub const table: [14][256]Transition = buildTable(false);
/// The table with 8-bit C1 controls enabled.
pub const table_c1: [14][256]Transition = buildTable(true);

fn t(a: ActionTag, n: State) Transition {
    return .{ .action = a, .next = n };
}

fn setRange(row: *[256]Transition, lo: u8, hi: u8, tr: Transition) void {
    var b: usize = lo;
    while (b <= hi) : (b += 1) row[b] = tr;
}

/// C0 controls other than CAN, SUB and ESC: 00-17, 19, 1C-1F.
fn setC0(row: *[256]Transition, tr: Transition) void {
    setRange(row, 0x00, 0x17, tr);
    row[0x19] = tr;
    setRange(row, 0x1C, 0x1F, tr);
}

/// Builds the transition table. `c1` enables the 8-bit C1 "anywhere" rules.
pub fn buildTable(comptime c1: bool) [14][256]Transition {
    @setEvalBranchQuota(100_000);
    var tab: [14][256]Transition = undefined;
    for (&tab, 0..) |*row, si| {
        const s: State = @enumFromInt(si);
        const self = t(.ignore, s);
        @memset(row, self);
        switch (s) {
            .ground => {
                setC0(row, t(.execute, s));
                setRange(row, 0x20, 0x7E, t(.print, s));
                row[0x7F] = self; // deviation: xterm ignores DEL
                setRange(row, 0x80, 0xFF, t(.print, s)); // UTF-8 decoder
            },
            .escape => {
                setC0(row, t(.execute, s));
                setRange(row, 0x20, 0x2F, t(.collect, .escape_intermediate));
                setRange(row, 0x30, 0x4F, t(.esc_dispatch, .ground));
                setRange(row, 0x51, 0x57, t(.esc_dispatch, .ground));
                row[0x59] = t(.esc_dispatch, .ground);
                row[0x5A] = t(.esc_dispatch, .ground);
                row[0x5C] = t(.esc_dispatch, .ground);
                setRange(row, 0x60, 0x7E, t(.esc_dispatch, .ground));
                row[0x50] = t(.ignore, .dcs_entry);
                row[0x58] = t(.ignore, .sos_pm_apc_string);
                row[0x5B] = t(.ignore, .csi_entry);
                row[0x5D] = t(.ignore, .osc_string);
                row[0x5E] = t(.ignore, .sos_pm_apc_string);
                row[0x5F] = t(.ignore, .sos_pm_apc_string);
                setRange(row, 0x80, 0xFF, t(.ignore, .csi_ignore));
            },
            .escape_intermediate => {
                setC0(row, t(.execute, s));
                setRange(row, 0x20, 0x2F, t(.collect, s));
                setRange(row, 0x30, 0x7E, t(.esc_dispatch, .ground));
                setRange(row, 0x80, 0xFF, t(.ignore, .csi_ignore));
            },
            .csi_entry => {
                setC0(row, t(.execute, s));
                setRange(row, 0x20, 0x2F, t(.collect, .csi_intermediate));
                setRange(row, 0x30, 0x39, t(.param, .csi_param));
                // Deviation: ':' separates sub-parameters (SGR 38:2::r:g:b,
                // 4:3), as documented in xterm ctlseqs, instead of csi_ignore.
                row[0x3A] = t(.param, .csi_param);
                row[0x3B] = t(.param, .csi_param);
                setRange(row, 0x3C, 0x3F, t(.collect, .csi_param));
                setRange(row, 0x40, 0x7E, t(.csi_dispatch, .ground));
                setRange(row, 0x80, 0xFF, t(.ignore, .csi_ignore));
            },
            .csi_param => {
                setC0(row, t(.execute, s));
                setRange(row, 0x20, 0x2F, t(.collect, .csi_intermediate));
                setRange(row, 0x30, 0x39, t(.param, s));
                row[0x3A] = t(.param, s); // deviation, see csi_entry
                row[0x3B] = t(.param, s);
                setRange(row, 0x3C, 0x3F, t(.ignore, .csi_ignore));
                setRange(row, 0x40, 0x7E, t(.csi_dispatch, .ground));
                setRange(row, 0x80, 0xFF, t(.ignore, .csi_ignore));
            },
            .csi_intermediate => {
                setC0(row, t(.execute, s));
                setRange(row, 0x20, 0x2F, t(.collect, s));
                setRange(row, 0x30, 0x3F, t(.ignore, .csi_ignore));
                setRange(row, 0x40, 0x7E, t(.csi_dispatch, .ground));
                setRange(row, 0x80, 0xFF, t(.ignore, .csi_ignore));
            },
            .csi_ignore => {
                setC0(row, t(.execute, s));
                setRange(row, 0x40, 0x7E, t(.ignore, .ground));
            },
            .dcs_entry => {
                setRange(row, 0x20, 0x2F, t(.collect, .dcs_intermediate));
                setRange(row, 0x30, 0x39, t(.param, .dcs_param));
                row[0x3A] = t(.ignore, .dcs_ignore);
                row[0x3B] = t(.param, .dcs_param);
                setRange(row, 0x3C, 0x3F, t(.collect, .dcs_param));
                setRange(row, 0x40, 0x7E, t(.hook, .dcs_passthrough));
                setRange(row, 0x80, 0xFF, t(.ignore, .dcs_ignore));
            },
            .dcs_param => {
                setRange(row, 0x20, 0x2F, t(.collect, .dcs_intermediate));
                setRange(row, 0x30, 0x39, t(.param, s));
                row[0x3A] = t(.ignore, .dcs_ignore);
                row[0x3B] = t(.param, s);
                setRange(row, 0x3C, 0x3F, t(.ignore, .dcs_ignore));
                setRange(row, 0x40, 0x7E, t(.hook, .dcs_passthrough));
                setRange(row, 0x80, 0xFF, t(.ignore, .dcs_ignore));
            },
            .dcs_intermediate => {
                setRange(row, 0x20, 0x2F, t(.collect, s));
                setRange(row, 0x30, 0x3F, t(.ignore, .dcs_ignore));
                setRange(row, 0x40, 0x7E, t(.hook, .dcs_passthrough));
                setRange(row, 0x80, 0xFF, t(.ignore, .dcs_ignore));
            },
            .dcs_passthrough => {
                setC0(row, t(.put, s));
                setRange(row, 0x20, 0x7E, t(.put, s));
                setRange(row, 0x80, 0xFF, t(.put, s));
            },
            .dcs_ignore => {},
            .osc_string => {
                row[0x07] = t(.ignore, .ground); // deviation: BEL terminates (xterm)
                setRange(row, 0x20, 0xFF, t(.put, s)); // includes DEL and UTF-8
            },
            .sos_pm_apc_string => {
                setRange(row, 0x20, 0xFF, t(.put, s));
            },
        }
        // "Anywhere" transitions.
        row[0x18] = t(.execute, .ground);
        row[0x1A] = t(.execute, .ground);
        row[0x1B] = t(.reenter, .escape);
        if (c1) {
            setRange(row, 0x80, 0x8F, t(.execute, .ground));
            setRange(row, 0x91, 0x97, t(.execute, .ground));
            row[0x99] = t(.execute, .ground);
            row[0x9A] = t(.execute, .ground);
            row[0x9C] = t(.ignore, .ground);
            row[0x90] = t(.reenter, .dcs_entry);
            row[0x9B] = t(.reenter, .csi_entry);
            row[0x9D] = t(.reenter, .osc_string);
            row[0x98] = t(.reenter, .sos_pm_apc_string);
            row[0x9E] = t(.reenter, .sos_pm_apc_string);
            row[0x9F] = t(.reenter, .sos_pm_apc_string);
        }
    }
    return tab;
}

test "Transition is one byte" {
    comptime std.debug.assert(@sizeOf(Transition) == 1);
}
