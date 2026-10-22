//! Protected paths (E16.F02.S01.T03, INV-05): writes always ask (except in
//! bypass mode) and sandboxes bind these read-only, so even an approved
//! command cannot rewrite the IDE's own configuration, git hooks or shell
//! profiles.

/// Path patterns (rule syntax) protected by default.
pub const default_protected = [_][]const u8{
    "./.zigguro/**",
    "./.zg/**",
    "./.git/hooks/**",
    "./.git/config",
    "./.mcp.json",
    "./.vscode/**",
    "./.cursor/**",
    "./.bashrc",
    "./.zshrc",
    "./.profile",
    "~/.config/zigguro/**",
    "~/.ssh/**",
    "~/.gitconfig",
    "~/.bashrc",
    "~/.zshrc",
    "~/.profile",
    "~/.bash_profile",
};
