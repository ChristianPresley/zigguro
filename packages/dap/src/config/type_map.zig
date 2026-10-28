//! VS Code debug `type`s to zigguro's adapters (E07.F06.S01.T02). A
//! configuration whose type maps to nothing is listed disabled, with the
//! reason.

const std = @import("std");

pub const Mapping = struct {
    /// The adapter (`AdapterDef.type`), or null when disabled.
    adapter: ?[]const u8,
    /// Why it is disabled (null when mapped).
    reason: ?[]const u8 = null,
};

const table = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lldb-dap", "lldb-dap" },
    .{ "lldb-vscode", "lldb-dap" },
    .{ "gdb", "gdb" },
    .{ "lldb", "codelldb" },
    .{ "codelldb", "codelldb" },
    .{ "debugpy", "debugpy" },
    .{ "python", "debugpy" },
    .{ "js-debug", "js-debug" },
    .{ "node", "js-debug" },
    .{ "pwa-node", "js-debug" },
    .{ "chrome", "js-debug" },
    .{ "pwa-chrome", "js-debug" },
});

/// The adapter for `type_name`; `args` is the configuration's object
/// (cppdbg looks at `MIMode`). `reason` strings are static or `a`'s.
pub fn map(a: std.mem.Allocator, type_name: []const u8, args: ?std.json.ObjectMap) std.mem.Allocator.Error!Mapping {
    if (table.get(type_name)) |t| return .{ .adapter = t };
    if (std.mem.eql(u8, type_name, "cppdbg")) {
        const mode: []const u8 = if (args) |o| if (o.get("MIMode")) |m| (if (m == .string) m.string else "") else "" else "";
        if (std.mem.eql(u8, mode, "gdb")) return .{ .adapter = null, .reason = "cppdbg (MIMode gdb) is the C/C++ extension's adapter: copy it as a \"gdb\" configuration to debug it here" };
        return .{ .adapter = null, .reason = "cppdbg is the C/C++ extension's adapter; use \"lldb-dap\" or \"gdb\" instead" };
    }
    if (std.mem.eql(u8, type_name, "cppvsdbg")) return .{ .adapter = null, .reason = "cppvsdbg (the Visual Studio debugger) only runs inside VS Code; use \"lldb-dap\" instead" };
    return .{ .adapter = null, .reason = try std.fmt.allocPrint(a, "No adapter for type \"{s}\"", .{type_name}) };
}
