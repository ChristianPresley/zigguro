//! "Chart this" (E13.F06.S01.T02): a chart spec (F07.S01.T03) inferred
//! from the selected columns of the grid's view:
//! - one number: a histogram;
//! - a date and a number: a line of the number's sum by date;
//! - a category and a number: bars of the number's sum per category;
//! - two numbers: a scatter, sampled to 100,000 points.
//! The data is the file and the view's query when the file has a
//! workspace path, else the view's rows inline (at most 100,000).

const std = @import("std");
const zg_agents = @import("zg_agents");
const grid_vm = @import("grid_vm.zig");

const Allocator = std.mem.Allocator;
const GridVM = grid_vm.GridVM;
const Kind = grid_vm.Kind;

pub const max_points = 100_000;

pub const Shape = enum { histogram, line, bar, scatter };

pub const Inferred = struct {
    shape: Shape,
    /// The x and y columns (y unused for a histogram).
    x: u32,
    y: u32 = 0,
};

/// What `cols` (with `kinds`) chart as, or null.
pub fn infer(cols: []const u32, kinds: []const Kind) ?Inferred {
    switch (cols.len) {
        1 => if (kinds[0] == .number) return .{ .shape = .histogram, .x = cols[0] },
        2 => {
            const a = kinds[0];
            const b = kinds[1];
            if (a == .number and b == .number) return .{ .shape = .scatter, .x = cols[0], .y = cols[1] };
            // The other column against the number.
            const num: usize = if (a == .number) 0 else if (b == .number) 1 else return null;
            const other = 1 - num;
            return switch (kinds[other]) {
                .temporal => .{ .shape = .line, .x = cols[other], .y = cols[num] },
                .category => .{ .shape = .bar, .x = cols[other], .y = cols[num] },
                .number => unreachable,
            };
        },
        else => {},
    }
    return null;
}

pub const hint = "Select one numeric column, a date or category column with a numeric one, or two numeric columns.";

/// The chart spec for the selection; error.Unchartable when `infer`
/// finds nothing.
pub fn spec(vm: *GridVM, a: Allocator, cols: []const u32) ![]const u8 {
    const kinds = try a.alloc(Kind, cols.len);
    for (kinds, cols) |*k, c| k.* = grid_vm.kindOf(vm.columnType(c));
    const inf = infer(cols, kinds) orelse return error.Unchartable;
    var s: std.json.Stringify = undefined;
    var w: std.Io.Writer.Allocating = .init(a);
    s = .{ .writer = &w.writer, .options = .{} };
    const xn = vm.columnName(inf.x);
    const yn = vm.columnName(inf.y);
    try s.beginObject();
    try s.objectField("title");
    try s.write(switch (inf.shape) {
        .histogram => try std.fmt.allocPrint(a, "Distribution of {s}", .{xn}),
        .line, .bar => try std.fmt.allocPrint(a, "{s} by {s}", .{ yn, xn }),
        .scatter => try std.fmt.allocPrint(a, "{s} against {s}", .{ yn, xn }),
    });
    try s.objectField("data");
    try writeData(vm, a, &s, inf);
    try s.objectField("mark");
    try s.write(switch (inf.shape) {
        .histogram, .bar => "bar",
        .line => "line",
        .scatter => "point",
    });
    try s.objectField("encoding");
    try s.beginObject();
    switch (inf.shape) {
        .histogram => {
            try s.objectField("x");
            try s.write(.{ .field = xn, .type = "quantitative", .bin = true });
            try s.objectField("y");
            try s.write(.{ .aggregate = "count", .type = "quantitative" });
        },
        .line => {
            try s.objectField("x");
            try s.write(.{ .field = xn, .type = "temporal" });
            try s.objectField("y");
            try s.write(.{ .field = yn, .type = "quantitative", .aggregate = "sum" });
        },
        .bar => {
            try s.objectField("x");
            try s.write(.{ .field = xn, .type = "nominal", .sort = "-y" });
            try s.objectField("y");
            try s.write(.{ .field = yn, .type = "quantitative", .aggregate = "sum" });
        },
        .scatter => {
            try s.objectField("x");
            try s.write(.{ .field = xn, .type = "quantitative" });
            try s.objectField("y");
            try s.write(.{ .field = yn, .type = "quantitative" });
        },
    }
    try s.endObject();
    try s.endObject();
    return w.written();
}

fn writeData(vm: *GridVM, a: Allocator, s: *std.json.Stringify, inf: Inferred) !void {
    try s.beginObject();
    if (vm.path) |p| {
        try s.objectField("path");
        try s.write(p);
        var q: std.Io.Writer.Allocating = .init(a);
        if (vm.view_text) |t| try q.writer.writeAll(t) else {
            try q.writer.writeAll("from ");
            try zg_agents.data.query.parser.writeName(&q.writer, vm.name);
        }
        if (inf.shape == .scatter) try q.writer.print(" | sample {d}", .{max_points});
        if (vm.view_text != null or inf.shape == .scatter) {
            try s.objectField("query");
            try s.write(q.written());
        }
        return s.endObject();
    }
    // Inline rows: evenly spaced when there are more.
    const n = vm.rowCount();
    const keep = @min(n, max_points);
    try s.objectField("values");
    try s.beginArray();
    const cols = [2]u32{ inf.x, inf.y };
    const used = cols[0..if (inf.shape == .histogram) 1 else 2];
    var i: u64 = 0;
    while (i < keep) : (i += 1) {
        const row = if (n > keep) i * n / keep else i;
        try s.beginObject();
        for (used) |c| {
            try s.objectField(vm.columnName(c));
            const e = try vm.cell(row, c);
            if (e.null_) try s.write(null) else try writeRaw(s, e.text, vm.columnType(c));
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// A shown cell back as JSON: numbers without separators.
fn writeRaw(s: *std.json.Stringify, text: []const u8, ty: zg_agents.data.query.types.Type) !void {
    switch (grid_vm.kindOf(ty)) {
        .number => {
            var buf: [64]u8 = undefined;
            var n: usize = 0;
            for (text) |c| if (c != ',' and n < buf.len) {
                buf[n] = c;
                n += 1;
            };
            if (std.fmt.parseFloat(f64, buf[0..n])) |f| return s.write(f) else |_| {}
            return s.write(text);
        },
        else => return s.write(text),
    }
}

test {
    std.testing.refAllDecls(@This());
}
