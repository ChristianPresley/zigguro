//! The debug adapters zigguro knows how to start (E07.F06.S01.T04). None
//! ships with zigguro: each is found on PATH (or named by a setting) and
//! comes with an install hint.

const std = @import("std");
const normalize = @import("normalize.zig");

const Allocator = std.mem.Allocator;

/// How the adapter talks.
pub const TransportKind = enum {
    /// DAP on the child's stdin and stdout.
    stdio,
    /// The child listens on `{port}` (picked free on 127.0.0.1) and we
    /// connect to it.
    tcp_listen_child,
};

pub const AdapterDef = struct {
    /// "lldb-dap", "gdb", "debugpy", "js-debug", "codelldb".
    type: []const u8,
    /// Other `type` values that mean this adapter.
    aliases: []const []const u8 = &.{},
    /// Shown in pickers.
    label: []const u8,
    /// argv; `{port}` is substituted for TCP adapters and `{path}` with
    /// the adapter's path setting.
    command: []const []const u8,
    transport: TransportKind = .stdio,
    languages: []const []const u8,
    min_version: ?std.SemanticVersion = null,
    version_args: []const []const u8 = &.{"--version"},
    supports_run_in_terminal: bool = true,
    /// Looked up on PATH without being configured.
    auto_discover: bool = true,
    /// The setting that must be set before it can run (no discovery).
    required_setting: ?[]const u8 = null,
    install_hint: []const u8,
    install_url: []const u8,
    normalize: ?*const fn (arena: Allocator, request: normalize.Request, args: *std.json.ObjectMap) anyerror!void = null,
};

pub const defs = [_]AdapterDef{
    .{
        .type = "lldb-dap",
        .aliases = &.{"lldb-vscode"},
        .label = "LLDB (lldb-dap)",
        .command = &.{"lldb-dap"},
        .languages = &.{ "zig", "c", "cpp", "rust", "swift", "objective-c" },
        .install_hint = "Install LLVM's lldb-dap (in LLVM 18 and later; older releases call it lldb-vscode) and put it on PATH.",
        .install_url = "https://lldb.llvm.org/use/lldbdap.html",
        .normalize = normalize.lldbDap,
    },
    .{
        .type = "gdb",
        .label = "GDB",
        .command = &.{ "gdb", "--quiet", "--interpreter=dap" },
        .languages = &.{ "zig", "c", "cpp", "rust", "go", "fortran", "ada" },
        .min_version = .{ .major = 14, .minor = 0, .patch = 0 },
        .install_hint = "Install GDB 14 or later (its DAP mode is new in 14) and put it on PATH.",
        .install_url = "https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html",
        .normalize = normalize.gdb,
    },
    .{
        .type = "debugpy",
        .aliases = &.{"python"},
        .label = "Python (debugpy)",
        .command = &.{ "{python}", "-m", "debugpy.adapter" },
        .languages = &.{"python"},
        .version_args = &.{ "-c", "import debugpy; print(debugpy.__version__)" },
        .install_hint = "Install debugpy into the Python you debug with: python -m pip install debugpy.",
        .install_url = "https://github.com/microsoft/debugpy",
        .normalize = normalize.debugpy,
    },
    .{
        .type = "js-debug",
        .aliases = &.{ "node", "pwa-node", "chrome", "pwa-chrome" },
        .label = "JavaScript (js-debug)",
        .command = &.{ "node", "{path}/src/dapDebugServer.js", "{port}", "127.0.0.1" },
        .transport = .tcp_listen_child,
        .languages = &.{ "javascript", "typescript", "javascriptreact", "typescriptreact" },
        .auto_discover = false,
        .required_setting = "debug.adapters.jsDebug.path",
        .version_args = &.{"--version"},
        .install_hint = "Download a js-debug-dap release, unpack it and set debug.adapters.jsDebug.path to its folder.",
        .install_url = "https://github.com/microsoft/vscode-js-debug/releases",
        .normalize = normalize.jsDebug,
    },
    .{
        .type = "codelldb",
        .aliases = &.{"lldb"},
        .label = "CodeLLDB (experimental)",
        .command = &.{},
        .transport = .tcp_listen_child,
        .languages = &.{ "zig", "c", "cpp", "rust" },
        .auto_discover = false,
        .required_setting = "debug.adapters.codelldb.command",
        .install_hint = "CodeLLDB is built for VS Code; set debug.adapters.codelldb.command to its adapter's argv (with {port}) to try it.",
        .install_url = "https://github.com/vadimcn/codelldb/blob/master/MANUAL.md",
        .normalize = normalize.lldbDap,
    },
};

/// The definition for `type_name` (or one of its aliases).
pub fn find(type_name: []const u8) ?*const AdapterDef {
    for (&defs) |*d| {
        if (std.mem.eql(u8, d.type, type_name)) return d;
        for (d.aliases) |al| if (std.mem.eql(u8, al, type_name)) return d;
    }
    return null;
}
