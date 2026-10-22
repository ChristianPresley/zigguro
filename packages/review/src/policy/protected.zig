//! Paths E12 never auto-applies (E12.F05.S01.T01): the IDE's own
//! configuration, version control internals, secrets, CI and the build.
//! Settings add to the list (`review.protected`); nothing removes from it.
//!
//! The workspace-relative entries of E16's `policy.default_protected`
//! (packages/security/src/policy/protected.zig) are repeated here: E16
//! stops writes outside the workspace itself, and zg_review does not
//! import zg_security.

pub const default_protected = [_][]const u8{
    // E12
    ".zigguro/**",
    ".git/**",
    "**/.env*",
    ".github/workflows/**",
    "build.zig",
    "build.zig.zon",
    // E16 (workspace-relative entries)
    ".zg/**",
    ".mcp.json",
    ".vscode/**",
    ".cursor/**",
    ".bashrc",
    ".zshrc",
    ".profile",
};
