//! Generates the terminal reference tables from their sources of truth:
//! `docs/modes.md` from `term.modes.mode_defs` and `docs/xtgettcap.md` from
//! `term.dcs.tcap`. Run with `zig build docs-terminal-modes`.

const std = @import("std");
const term = @import("zg_terminal").term;

pub fn main(min: std.process.Init.Minimal) !u8 {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(min.args), .environ = min.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try min.args.toSlice(arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: zg_terminal-docs <docs dir>\n", .{});
        return 2;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try modes(&out.writer);
    try dir.writeFile(io, .{ .sub_path = "modes.md", .data = out.written() });
    out.clearRetainingCapacity();
    try xtgettcap(&out.writer);
    try dir.writeFile(io, .{ .sub_path = "xtgettcap.md", .data = out.written() });
    return 0;
}

fn modes(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# Terminal modes
        \\
        \\Generated from `src/term/modes.zig` by `zig build docs-terminal-modes`; do not edit.
        \\
        \\Set with `CSI Pm h` (ANSI) or `CSI ? Pm h` (DEC), reset with `l`, query with DECRQM
        \\(`CSI [?] Pd $ p`, reply `CSI [?] Pd ; Ps $ y`), save and restore DEC modes with
        \\XTSAVE/XTRESTORE (`CSI ? Pm s` / `CSI ? Pm r`).
        \\
        \\| Mode | Kind | Name | Default | DECRQM |
        \\|---:|---|---|---|---|
        \\
    );
    for (term.modes.mode_defs) |d| {
        try w.print("| {d} | {s} | `{s}` | {s} | {s} |\n", .{
            d.value,
            if (d.kind == .ansi) "ANSI" else "DEC",
            d.name,
            if (d.default) "set" else "reset",
            switch (d.report) {
                .normal => "1 / 2",
                .perm_set => "3 (permanently set)",
                .perm_reset => "4 (permanently reset)",
            },
        });
    }
    try w.writeAll("\nAny other mode number reports 0 (not recognised).\n");
}

fn xtgettcap(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# XTGETTCAP
        \\
        \\Generated from `src/term/dcs.zig` by `zig build docs-terminal-modes`; do not edit.
        \\
        \\`DCS + q <hex name>[;<hex name>...] ST` is answered per name with
        \\`DCS 1 + r <hex name>=<hex value> ST`, or `DCS 0 + r <hex name> ST` when the
        \\name is unknown. Values follow terminfo conventions (`\E` is ESC); `Smulx`,
        \\`Setulc` and `Sync` match kitty's and foot's terminfo entries, `Ms` is xterm's
        \\OSC 52 capability.
        \\
        \\| Name | Value |
        \\|---|---|
        \\
    );
    for (term.dcs.tcap) |e| {
        try w.print("| `{s}` | `", .{e[0]});
        for (e[1]) |c| switch (c) {
            0x1b => try w.writeAll("\\E"),
            0x07 => try w.writeAll("^G"),
            0x7f => try w.writeAll("^?"),
            '|' => try w.writeAll("\\|"),
            else => try w.writeByte(c),
        };
        try w.writeAll("` |\n");
    }
}
