//! Benchmarks for zg_codeintel; run with `zig build bench` at the repo root.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_codeintel = @import("zg_codeintel");
const zg_syntax = @import("zg_syntax");
const bench = zg_core.bench;
const State = bench.State;
const Registry = zg_codeintel.registry.Registry;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("codeintel.registry.discover: 6 builtin servers, 6-entry PATH, cold cache", {}, discover);
    try b.run("codeintel.semtok.decode_200k: full result, 20k lines x 10 tokens", {}, decode200k);
    // The fixture is built once, outside the measured calls.
    var fx: DiagFixture = undefined;
    fx.init(std.heap.smp_allocator);
    defer fx.deinit();
    try b.run("codeintel.diag.convert_10k: parse and convert a 10k-diagnostic push (worker)", &fx, diagConvert10k);
    try b.run("codeintel.diag.apply_10k: map 10k diagnostics to bytes and publish (UI)", &fx, diagApply10k);
}

/// A typical PATH; most builtin servers are absent, so every entry is
/// probed for them (the slow case). Budget: < 20 ms per discovery.
const path_var = if (builtin.os.tag == .windows)
    "C:\\Windows\\system32;C:\\Windows;C:\\Windows\\System32\\Wbem;C:\\Program Files\\Git\\cmd;C:\\Users\\Default\\AppData\\Local\\Microsoft\\WindowsApps;C:\\zig"
else
    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

fn discover(_: void, s: *State) void {
    const gpa = s.allocator();
    const io = s.ioHandle();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    env.put("PATH", path_var) catch unreachable;
    var r = Registry.init(gpa, .{}) catch unreachable;
    defer r.deinit();
    var found: usize = 0;
    for (0..s.iterations()) |_| {
        r.rescan();
        for (r.defs) |*d| {
            if (r.resolveExecutable(io, d, &env) catch unreachable) |_| found += 1;
        }
    }
    bench.doNotOptimizeAway(found);
}

const line_text = "word word word word word word word word word word";

fn sameLine(_: *const anyopaque, _: u64, _: *std.ArrayList(u8), _: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    return line_text;
}

/// Decoding a 200k-token full result into the overlay. Budget: < 5 ms.
fn decode200k(_: void, s: *State) void {
    const gpa = s.allocator();
    const lines = 20_000;
    const data = gpa.alloc(u32, lines * 10 * 5) catch unreachable;
    defer gpa.free(data);
    for (0..lines * 10) |i| {
        const first = i % 10 == 0;
        data[i * 5 ..][0..5].* = .{ @intFromBool(first and i > 0), if (first) 0 else 5, 4, @intCast(i % 3), @intCast(i % 2) };
    }
    var names: zg_syntax.HighlightNames = .init(gpa);
    defer names.deinit();
    var legend = (zg_syntax.SemanticLegend{ .types = &.{ "variable", "function", "type" }, .modifiers = &.{"readonly"} }).compile(gpa, &names) catch unreachable;
    defer legend.deinit();
    const src: zg_syntax.LineSource = .{ .ctx = &names, .lines = lines + 1, .getFn = sameLine };
    for (0..s.iterations()) |i| {
        var o = zg_syntax.SemanticOverlay.init(gpa, lines + 1, 1) catch unreachable;
        defer o.deinit();
        o.enc = .utf8;
        const ok = o.applyFull(1, "r", data, &legend, src) catch unreachable;
        bench.doNotOptimizeAway(ok);
        bench.doNotOptimizeAway(i);
    }
}

const diag = zg_codeintel.diagnostics;
const diag_count = 10_000;

/// A `publishDiagnostics` with one diagnostic on each of 10k lines.
fn pushJson(gpa: std.mem.Allocator) []u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    w.writer.writeAll("{\"uri\":\"file:///w/main.zig\",\"version\":1,\"diagnostics\":[") catch unreachable;
    for (0..diag_count) |i| {
        if (i > 0) w.writer.writeByte(',') catch unreachable;
        w.writer.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":6}},\"end\":{{\"line\":{d},\"character\":10}}}},\"severity\":{d},\"source\":\"zls\",\"code\":\"E{d}\",\"message\":\"use of undeclared identifier 'word'\"}}", .{ i, i, i % 4 + 1, i % 8 }) catch unreachable;
    }
    w.writer.writeAll("]}") catch unreachable;
    return w.toOwnedSlice() catch unreachable;
}

const DiagFixture = struct {
    gpa: std.mem.Allocator,
    json: []u8,
    /// The converted push.
    template: *diag.Store.Set,
    /// 10k lines of text.
    doc: *Document,

    fn init(fx: *DiagFixture, gpa: std.mem.Allocator) void {
        fx.gpa = gpa;
        fx.json = pushJson(gpa);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const p = diag.convert.parsePush(arena.allocator(), fx.json) catch unreachable;
        fx.template = diag.Store.Set.create(gpa, .{ .server = 0 }) catch unreachable;
        diag.convert.fromLsp(fx.template, p.diagnostics) catch unreachable;
        const text = arena.allocator().alloc(u8, (line_text.len + 1) * diag_count) catch unreachable;
        for (0..diag_count) |i| {
            @memcpy(text[i * (line_text.len + 1) ..][0..line_text.len], line_text);
            text[i * (line_text.len + 1) + line_text.len] = '\n';
        }
        fx.doc = Document.initBytes(gpa, @enumFromInt(1), text) catch unreachable;
    }

    fn deinit(fx: *DiagFixture) void {
        fx.doc.deinit();
        fx.template.destroy();
        fx.gpa.free(fx.json);
    }
};

/// What the reader thread does per push. Budget: < 10 ms.
fn diagConvert10k(fx: *DiagFixture, s: *State) void {
    const gpa = s.allocator();
    s.setBytes(fx.json.len);
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const p = diag.convert.parsePush(arena.allocator(), fx.json) catch unreachable;
        const set = diag.Store.Set.create(gpa, .{ .server = 0 }) catch unreachable;
        defer set.destroy();
        diag.convert.fromLsp(set, p.diagnostics) catch unreachable;
        bench.doNotOptimizeAway(set.diags.len);
    }
}

/// What the UI thread does per push: byte ranges against the document,
/// replace and commit (copying the converted diagnostics stands in for
/// taking them from the worker). Budget: < 2 ms.
fn diagApply10k(fx: *DiagFixture, s: *State) void {
    const gpa = s.allocator();
    var st = diag.Store.init(gpa, s.ioHandle(), .posix) catch unreachable;
    defer st.deinit();
    for (0..s.iterations()) |_| {
        const set = diag.Store.Set.create(gpa, .{ .server = 0 }) catch unreachable;
        set.diags = set.allocator().dupe(diag.Store.Diagnostic, fx.template.diags) catch unreachable;
        set.counts = fx.template.counts;
        diag.convert.mapBytes(gpa, set, &fx.doc.tree, .utf16, fx.doc.version) catch unreachable;
        st.replace("/w/main.zig", .{ .server = 0 }, set) catch unreachable;
        st.commit();
    }
    bench.doNotOptimizeAway(st.current.generation);
}

const Document = @import("zg_editor").model.document.Document;
