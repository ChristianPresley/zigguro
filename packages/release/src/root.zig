//! zg_release: release identity shared by every binary and tool.
//!
//! - `Version`: strict SemVer 2.0.0 with §11 precedence.
//! - `BuildInfo` / `current`: what this binary is (comptime, from build options).
//! - `product`: product constants from `packaging/product.zon`.
//! - `minisign`: minisign-compatible Ed25519 signing and verification.
//!
//! Pure functions over byte slices; no file or network I/O.

const std = @import("std");

/// SemVer 2.0.0 version.
pub const Version = @import("version.zig").Version;
/// Build identity types and the comptime `current` value.
pub const build_info = @import("build_info.zig");
/// Identity of one build.
pub const BuildInfo = build_info.BuildInfo;
/// Release channel.
pub const Channel = build_info.Channel;
/// Update mode baked into the binary.
pub const UpdateMode = build_info.UpdateMode;
/// The `BuildInfo` of this binary.
pub const current = build_info.current;
/// Product constants module (types and URL helpers).
pub const product_info = @import("product.zig");
/// The product constants of this build.
pub const product = product_info.product;
/// Minisign-compatible Ed25519 signing and verification.
pub const minisign = @import("minisign.zig");
/// `--version` handling run before runtime init.
pub const cli = @import("cli.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("version.zig");
    _ = @import("build_info.zig");
    _ = @import("product.zig");
    _ = @import("cli.zig");
    _ = @import("minisign.zig");
}
