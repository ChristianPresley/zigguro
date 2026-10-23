//! The column profile (E13.F06.S01.T02): `computeStats` for the
//! selected column on a worker (cancelled when the column changes), shown
//! as counts, range, quantiles, a histogram sparkline drawn on the vector
//! canvas, and the most frequent values (a click filters by one).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const vector_view = @import("../vector_view.zig");
const grid_vm = @import("grid_vm.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const data = zg_agents.data;
const vector = zg_agents.vector;
const ColumnStats = data.stats.ColumnStats;

pub const spark_w: f32 = 220;
pub const spark_h: f32 = 40;

const Job = struct {
    panel: *ProfilePanel,
    col: u32,
    arena: std.heap.ArenaAllocator,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    stats: ?ColumnStats = null,
    err: ?anyerror = null,
    future: ?Io.Future(void) = null,
};

pub const ProfilePanel = struct {
    gpa: Allocator,
    io: Io,
    ds: *data.Dataset,
    surface: *vector_view.VectorSurface,
    wake: ?grid_vm.Hook = null,
    job: ?*Job = null,
    /// The column shown (or being computed).
    col: ?u32 = null,
    /// Set when a job finished and its histogram is not drawn yet.
    drawn: bool = false,

    pub fn init(gpa: Allocator, io: Io, app: *zg_gui.App, ds: *data.Dataset) !*ProfilePanel {
        const p = try gpa.create(ProfilePanel);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .ds = ds, .surface = try .init(gpa, io, app, .{ .threads = 1 }) };
        return p;
    }

    /// Call when no tile job is pending (`App.joinWork` first).
    pub fn deinit(p: *ProfilePanel) void {
        p.stop();
        p.surface.deinit();
        p.gpa.destroy(p);
    }

    fn stop(p: *ProfilePanel) void {
        const j = p.job orelse return;
        j.cancel.store(true, .release);
        if (j.future) |*f| f.await(p.io);
        j.arena.deinit();
        p.gpa.destroy(j);
        p.job = null;
    }

    /// Profiles source column `col` (null: none).
    pub fn show(p: *ProfilePanel, col: ?u32) !void {
        if (std.meta.eql(p.col, col) and (col == null or p.job != null)) return;
        p.stop();
        p.col = col;
        p.drawn = false;
        const c = col orelse return;
        const j = try p.gpa.create(Job);
        j.* = .{ .panel = p, .col = c, .arena = .init(p.gpa) };
        p.job = j;
        j.future = p.io.concurrent(run, .{j}) catch blk: {
            run(j);
            break :blk null;
        };
    }

    fn run(j: *Job) void {
        const p = j.panel;
        if (data.stats.computeStats(p.io, p.ds, j.col, j.arena.allocator(), &j.cancel)) |s| j.stats = s else |e| j.err = e;
        j.done.store(true, .release);
        if (!j.cancel.load(.acquire)) if (p.wake) |w| w.f(w.ctx);
    }

    /// The stats once computed.
    pub fn stats(p: *const ProfilePanel) ?*const ColumnStats {
        const j = p.job orelse return null;
        if (!j.done.load(.acquire)) return null;
        return if (j.stats) |*s| s else null;
    }

    pub fn computing(p: *const ProfilePanel) bool {
        const j = p.job orelse return false;
        return !j.done.load(.acquire);
    }

    /// Records the histogram once the stats are in.
    fn drawSpark(p: *ProfilePanel, s: *const ColumnStats) !void {
        if (p.drawn) return;
        p.drawn = true;
        const cv = try p.surface.begin();
        var hi: u64 = 1;
        for (s.histogram) |n| hi = @max(hi, n);
        const bw = spark_w / @as(f32, @floatFromInt(s.histogram.len));
        for (s.histogram, 0..) |n, i| {
            if (n == 0) continue;
            const h = @max(1, spark_h * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(hi)));
            try cv.fillRect(.xywh(@as(f32, @floatFromInt(i)) * bw, spark_h - h, @max(1, bw - 1), h), .rgb(0x4C78A8));
        }
        try p.surface.commit();
    }
};

/// What a click on a top value asks for.
pub const Action = union(enum) { none, filter_equals: []const u8 };

/// The panel for the vm's source column `p.col`.
pub fn profilePanel(ui: *Ui, p: *ProfilePanel, vm: *grid_vm.GridVM) Action {
    const th = ui.theme();
    var action: Action = .none;
    ui.open(.{ .role = .group, .label = "Column profile", .test_id = "data-profile", .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .w = .{ .px = spark_w + 2 * th.dim(.space_sm) }, .shrink = 0 } });
    defer ui.close();
    const col = p.col orelse {
        ui.text("Select a column to profile it.", .{ .color = .fg_muted });
        return action;
    };
    ui.text(vm.ds.columns[col], .{ .style = .{ .weight = 700 }, .wrap = false });
    if (p.computing()) {
        ui.text("Profiling…", .{ .color = .fg_muted });
        return action;
    }
    const s = p.stats() orelse {
        ui.text("Could not profile this column.", .{ .color = .danger });
        return action;
    };
    const a = ui.arena();
    line(ui, "Type", @tagName(zg_agents.data.query.types.Type.fromCol(s.ty)));
    line(ui, "Values", grouped(a, s.count));
    line(ui, "Nulls", grouped(a, s.nulls));
    line(ui, "Distinct", std.fmt.allocPrint(a, "≈ {s}", .{grouped(a, s.distinct_est)}) catch "");
    if (s.min) |v| line(ui, "Min", grid_vm.formatValue(a, grid_vm.fromInfer(v)) catch "");
    if (s.max) |v| line(ui, "Max", grid_vm.formatValue(a, grid_vm.fromInfer(v)) catch "");
    if (s.mean) |m| line(ui, "Mean", grid_vm.formatValue(a, .{ .float = roundTo(m, 4) }) catch "");
    if (s.quantiles[2]) |q| line(ui, "Median", grid_vm.formatValue(a, .{ .float = roundTo(q, 4) }) catch "");
    if (s.hist_range != null) {
        p.drawSpark(s) catch {};
        vector_view.vectorView(ui, p.surface, .{ .w = spark_w, .h = spark_h, .label = "Histogram", .test_id = "data-profile-histogram" });
    }
    if (s.sampled) ui.text("From a sample of the rows.", .{ .color = .fg_muted });
    if (s.top.len > 0 and (s.ty == .string or s.ty == .bool_)) {
        ui.text("Most frequent", .{ .style = .{ .weight = 700 } });
        for (s.top[0..@min(s.top.len, 10)], 0..) |t, i| {
            ui.id(@as(u64, i));
            const label = std.fmt.allocPrint(a, "{s}  ({s})", .{ if (t.v.len == 0) grid_vm.null_mark else t.v, grouped(a, t.n) }) catch continue;
            if (controls.button(ui, .{ .label = label, .variant = .ghost }).clicked) action = .{ .filter_equals = t.v };
        }
    }
    return action;
}

fn line(ui: *Ui, k: []const u8, v: []const u8) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 8 } });
    defer ui.close();
    ui.text(k, .{ .color = .fg_muted, .wrap = false });
    ui.text(v, .{ .wrap = false });
}

fn grouped(a: Allocator, n: u64) []const u8 {
    var w: Io.Writer.Allocating = .init(a);
    grid_vm.writeGrouped(&w.writer, n) catch return "";
    return w.written();
}

fn roundTo(x: f64, sig: u8) f64 {
    if (x == 0 or !std.math.isFinite(x)) return x;
    const e = @floor(std.math.log10(@abs(x)));
    const k = std.math.pow(f64, 10, @as(f64, @floatFromInt(sig)) - 1 - e);
    return @round(x * k) / k;
}

test {
    std.testing.refAllDecls(@This());
}
