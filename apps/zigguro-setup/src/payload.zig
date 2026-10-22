//! The release zip embedded in an installer build (`-Dsetup-payload`).
//! The helper copy shipped inside `app\` is built without one and only
//! uninstalls and applies updates.

const options = @import("setup_options");

/// True in installer builds.
pub const has_payload: bool = options.has_payload;
/// The release zip.
pub const bytes: []const u8 = if (has_payload) @embedFile("payload") else "";
/// The version in the payload's `BUILDINFO.zon`.
pub const version: []const u8 = options.payload_version;
/// The payload's release target (`BuildInfo.target`).
pub const target: []const u8 = options.payload_target;
