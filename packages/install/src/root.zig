//! zg_install: desktop integration for installs (E17.F02, E17.F03).
//!
//! - `receipt`: the install receipt (`<root>/receipt.zon`), shared by the
//!   Windows and Linux integrations.
//! - `win`: HKCU registrations, the user's PATH, Start Menu and desktop
//!   shortcuts, and their reversal. The registry logic runs against an
//!   in-memory registry on every OS; the real registry and COM only on
//!   Windows.

const std = @import("std");

/// The install receipt.
pub const receipt = @import("receipt.zig");
pub const Receipt = receipt.Receipt;
pub const ReceiptBuilder = receipt.ReceiptBuilder;
pub const InstallOptions = receipt.InstallOptions;
/// Windows integration.
pub const win = @import("win/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = receipt;
    _ = win;
}
