//! Lexing one line through the injection stack: the running language lexes
//! until it pushes a guest, pops itself, or reaches the host's end
//! delimiter for it, and the framework hands the rest of the line on.

const std = @import("std");
const state_mod = @import("state.zig");
const scanner_mod = @import("scanner.zig");
const Registry = @import("../registry.zig").Registry;

const LexState = state_mod.LexState;
const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.Token;
const TokenSink = scanner_mod.TokenSink;

/// Lines longer than this get one plain token and keep their start state.
pub const max_tokenized_line = 20_000;

/// Hand-offs within one line before the rest is left plain (a guard
/// against languages that push and pop without consuming input).
const max_handoffs = 16;

/// Lexes `line` (without its EOL) starting in `st`, leaving `st` as the
/// line's end state. The sink must have been begun for this line.
pub fn lexLine(reg: *const Registry, st: *LexState, line: []const u8, sink: *TokenSink) void {
    if (line.len > max_tokenized_line) {
        sink.push(.{ .start = 0, .kind = 0, .hl = .none });
        return;
    }
    var pos: u32 = 0;
    var handoffs: u32 = 0;
    while (true) {
        const lang = reg.getOrPlain(st.top());
        var view_end: usize = line.len;
        if (st.injected()) {
            const host_frame = st.stack[st.stack_len - 2];
            const host = reg.getOrPlain(host_frame.lang);
            if (host.injection_end) |f| if (f(host_frame.mode, line, pos)) |e| {
                view_end = @max(e, pos);
            };
        }
        sink.kind_or = if (st.injected()) Token.injected_bit else 0;
        var s: Scanner = .{ .line = line[0..view_end], .pos = pos };
        const depth = st.stack_len;
        const top = st.top();
        lang.lexer.lexLineFn(st, &s, sink);
        pos = s.pos;
        const switched = st.stack_len != depth or st.top() != top;
        if (!switched and pos < view_end) {
            // The lexer stopped early without handing off: leave the rest plain.
            sink.push(.{ .start = pos, .kind = 0, .hl = .none });
            pos = @intCast(view_end);
        }
        if (!switched and view_end == line.len) break;
        if (!switched) {
            // The host's end delimiter: the guest is done.
            st.pop();
        }
        if (pos >= line.len) break;
        handoffs += 1;
        if (handoffs >= max_handoffs) {
            sink.kind_or = 0;
            sink.push(.{ .start = pos, .kind = 0, .hl = .none });
            break;
        }
    }
    sink.kind_or = 0;
}
