//! Charts (E13.F07.S01.T03): a compact JSON spec models write reliably,
//! read strictly (errors name their JSON path), compiled through
//! transforms, scales, nice ticks and layout into marks, and drawn on
//! the vector canvas with hover tooltips. The format is documented in
//! docs/formats/chart.md.

pub const validate = @import("validate.zig");
pub const spec = @import("spec.zig");
pub const transform = @import("transform.zig");
pub const scale = @import("scale.zig");
pub const ticks = @import("ticks.zig");
pub const layout = @import("layout.zig");
pub const decimate = @import("decimate.zig");
pub const hit = @import("hit.zig");
pub const compile_mod = @import("compile.zig");
pub const render_mod = @import("render.zig");
pub const schema = @import("schema.zig");

pub const ChartSpec = spec.ChartSpec;
pub const Mark = spec.Mark;
pub const FieldType = spec.FieldType;
pub const Aggregate = spec.Aggregate;
pub const SpecError = spec.SpecError;
pub const Diagnostic = spec.Diagnostic;
pub const parseSpec = spec.parseSpec;
pub const Table = transform.Table;
pub const CompiledChart = compile_mod.CompiledChart;
pub const Options = compile_mod.Options;
pub const DataSource = compile_mod.DataSource;
pub const Tooltip = compile_mod.Tooltip;
pub const compile = compile_mod.compile;
pub const render = render_mod.render;
pub const hitTest = compile_mod.hitTest;
pub const niceTicks = ticks.niceTicks;
pub const TickSet = ticks.TickSet;

/// Reads `json` as a spec: null when it is valid, else the message
/// (JSON path first). The artifact store's chart validator.
pub fn checkSpec(_: *anyopaque, arena: @import("std").mem.Allocator, json: []const u8) anyerror!?[]const u8 {
    var diag: Diagnostic = .{};
    _ = parseSpec(arena, json, &diag) catch |e| switch (e) {
        error.InvalidSpec => return diag.message,
        else => |x| return x,
    };
    return null;
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("spec_test.zig");
    _ = @import("ticks_test.zig");
    _ = @import("render_test.zig");
}
