//! GPU memory management (E02.F03): the TLSF suballocator so far.

/// See `tlsf.zig`.
pub const tlsf = @import("tlsf.zig");
/// See `tlsf.zig`.
pub const Tlsf = tlsf.Tlsf;

test {
    _ = tlsf;
}
