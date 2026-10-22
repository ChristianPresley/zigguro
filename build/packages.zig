//! The comptime package table composed by the root `build.zig`.
//! `zig build new-package` appends entries before the insert marker.

/// One entry of the package table.
pub const Package = struct {
    /// zon `.name` and root module name, e.g. "zg_core".
    name: []const u8,
    /// Directory relative to the repository root.
    dir: []const u8,
    /// Whether the package has `bench/main.zig` (an installed `<name>-bench` artifact).
    has_bench: bool = false,

    /// Short name used for `test-<short>` steps: the name without "zg_".
    pub fn short(p: Package) []const u8 {
        const prefix = "zg_";
        if (p.name.len > prefix.len and @import("std").mem.startsWith(u8, p.name, prefix)) return p.name[prefix.len..];
        return p.name;
    }
};

/// Every runtime package in the repository, lowest layer first.
pub const all = [_]Package{
    .{ .name = "zg_core", .dir = "packages/core", .has_bench = true },
    .{ .name = "zg_jsonrpc", .dir = "packages/jsonrpc", .has_bench = true },
    .{ .name = "zg_net", .dir = "packages/net", .has_bench = true },
    .{ .name = "zg_terminal", .dir = "packages/terminal", .has_bench = true },
    .{ .name = "zg_mcp", .dir = "packages/mcp", .has_bench = true },
    .{ .name = "zg_lsp", .dir = "packages/lsp", .has_bench = true },
    .{ .name = "zg_dap", .dir = "packages/dap", .has_bench = true },
    .{ .name = "zg_text", .dir = "packages/text", .has_bench = true },
    .{ .name = "zg_git", .dir = "packages/git", .has_bench = true },
    .{ .name = "zg_scm", .dir = "packages/scm", .has_bench = true },
    .{ .name = "zg_platform", .dir = "packages/platform", .has_bench = true },
    .{ .name = "zg_security", .dir = "packages/security", .has_bench = true },
    .{ .name = "zg_ai", .dir = "packages/ai", .has_bench = true },
    .{ .name = "zg_release", .dir = "packages/release", .has_bench = true },
    .{ .name = "zg_update", .dir = "packages/update", .has_bench = true },
    .{ .name = "zg_crash", .dir = "packages/crash", .has_bench = true },
    // pkgtool:insert
};

/// Index of the package named `name` in `all` (a compile error if absent).
pub fn indexOf(comptime name: []const u8) usize {
    for (all, 0..) |p, i| {
        if (@import("std").mem.eql(u8, p.name, name)) return i;
    }
    @compileError("unknown package " ++ name);
}
