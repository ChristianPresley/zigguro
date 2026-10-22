//! Benchmarks for zg_lsp; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("lsp.glob: **/*.{zig,zon} on 60-byte paths", {}, globMatch);
    try b.run("lsp.fuzzy.20k: 20k identifiers x 3 patterns", {}, fuzzy20k);
    try b.run("lsp.caps.supports: 50 registrations, selector match", {}, capsSupports);
    try b.run("lsp.sched.keystroke: onDocChanged + schedule, 6 keys", {}, schedKeystroke);
}

const paths = [_][]const u8{
    "packages/lsp/src/features/completion/engine_internal_x.zig",
    "packages/editor/src/buffer/piece_tree/node_storage_abcd.zon",
    "packages/terminal/src/vt/parser/state_machine_tables_ab.txt",
    "apps/zigguro/src/main/window/frame_scheduler_internals.zig",
};

fn globMatch(_: void, s: *State) void {
    const gpa = s.allocator();
    var g = zg_lsp.glob.Glob.compile(gpa, "**/*.{zig,zon}", .{ .case_insensitive = false }) catch unreachable;
    defer g.deinit(gpa);
    var hits: usize = 0;
    for (0..s.iterations()) |i| {
        if (g.match(paths[i & 3])) hits += 1;
    }
    bench.doNotOptimizeAway(hits);
}

fn fuzzy20k(_: void, s: *State) void {
    const gpa = s.allocator();
    const n = 20_000;
    const words = gpa.alloc([]u8, n) catch unreachable;
    defer {
        for (words) |w| gpa.free(w);
        gpa.free(words);
    }
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    const parts = [_][]const u8{ "get", "set", "Buffer", "parse", "_args", "Node", "tree", "Index", "count", "lsp", "Request", "id" };
    for (words) |*w| {
        var buf: [96]u8 = undefined;
        var len: usize = 0;
        for (0..2 + r.uintLessThan(usize, 4)) |_| {
            const p = parts[r.uintLessThan(usize, parts.len)];
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
        }
        w.* = gpa.dupe(u8, buf[0..len]) catch unreachable;
    }
    const patterns = [_]zg_lsp.fuzzy.Fuzzy{ .init("gbi"), .init("parseNode"), .init("req") };
    const scratch = gpa.create(zg_lsp.fuzzy.Scratch) catch unreachable;
    defer gpa.destroy(scratch);
    for (0..s.iterations()) |_| {
        var total: i64 = 0;
        for (&patterns) |*p| {
            for (words) |w| total += p.score(w, scratch, null) orelse 0;
        }
        bench.doNotOptimizeAway(total);
    }
}

fn capsSupports(_: void, s: *State) void {
    const gpa = s.allocator();
    const caps = zg_lsp.client.caps;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: zg_lsp.protocol.ServerCapabilities = .{};
    var c = caps.ServerCaps.fromInitializeResult(gpa, &empty, .{ .roots = &.{"/ws"} }) catch unreachable;
    defer c.deinit();
    // 50 registrations spread over the methods a server typically
    // registers dynamically, all for another language.
    const methods = [_][]const u8{
        "textDocument/codeLens",       "textDocument/definition", "textDocument/references",   "textDocument/documentSymbol",
        "textDocument/formatting",     "textDocument/rename",     "textDocument/foldingRange", "textDocument/semanticTokens",
        "textDocument/inlayHint",      "textDocument/codeAction", "textDocument/completion",   "textDocument/signatureHelp",
        "textDocument/implementation",
    };
    for (0..50) |i| {
        const opts = std.json.parseFromSliceLeaky(std.json.Value, a, "{\"documentSelector\": [{\"language\": \"rust\"}, {\"pattern\": \"**/*.rs\"}]}", .{}) catch unreachable;
        c.addRegistration(.{ .id = std.fmt.allocPrint(a, "r{d}", .{i}) catch unreachable, .method = methods[i % methods.len], .registerOptions = opts }) catch unreachable;
    }
    const hover_opts = std.json.parseFromSliceLeaky(std.json.Value, a, "{\"documentSelector\": [{\"language\": \"zig\"}]}", .{}) catch unreachable;
    c.addRegistration(.{ .id = "hover", .method = "textDocument/hover", .registerOptions = hover_opts }) catch unreachable;
    const doc: zg_lsp.client.doc_selector.DocMatch = .{ .language_id = "zig", .scheme = "file", .path = "/ws/src/main.zig" };
    var hits: usize = 0;
    for (0..s.iterations()) |i| {
        if (c.supports(if (i & 1 == 0) .hover else .code_lens, doc)) hits += 1;
    }
    bench.doNotOptimizeAway(hits);
}

fn schedKeystroke(_: void, s: *State) void {
    const sched = zg_lsp.sync.scheduler;
    var rt: zg_core.Runtime = undefined;
    rt.initBorrowed(s.allocator(), s.ioHandle(), 16) catch unreachable;
    defer _ = rt.deinit();
    var clock: sched.ManualClock = .{};
    var q: sched.RequestScheduler = .init(&rt, clock.clock());
    defer q.deinit();
    const Noop = struct {
        fn run(_: ?*anyopaque, _: u64, _: sched.CancelToken) void {}
    };
    const run: sched.RunFn = .{ .ctx = null, .func = Noop.run };
    const features = [_]zg_lsp.client.caps.Feature{ .semantic_tokens_full, .inlay_hint, .code_lens, .folding_range, .document_symbol, .diagnostic_pull };
    for (features) |f| q.schedule(.{ .doc = 1, .feature = f }, q.debounceFor(f), run) catch unreachable;
    for (0..s.iterations()) |i| {
        // One keystroke: the document changes and completion-style
        // features are rescheduled.
        q.onDocChanged(1, i);
        q.schedule(.{ .doc = 1, .feature = .inlay_hint }, q.debounceFor(.inlay_hint), run) catch unreachable;
    }
    bench.doNotOptimizeAway(q.version(1));
}
