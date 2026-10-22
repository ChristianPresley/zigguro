//! The VT byte-stream parser (E06.F02.S01): a table-driven DEC ANSI state
//! machine with a SIMD ground-state fast path and streaming UTF-8 decoding.

pub const Parser = @import("vt/Parser.zig");
pub const Csi = Parser.Csi;
pub const Esc = Parser.Esc;
pub const StringTerm = Parser.StringTerm;
pub const State = Parser.State;
pub const table = @import("vt/table.zig");
pub const fast_path = @import("vt/fast_path.zig");
pub const utf8 = @import("vt/utf8.zig");
pub const handlers = @import("vt/handlers.zig");
pub const NullHandler = handlers.NullHandler;
pub const RecordingHandler = handlers.RecordingHandler;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("vt/params.zig");
}
