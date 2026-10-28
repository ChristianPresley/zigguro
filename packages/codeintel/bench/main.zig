//! Benchmarks for zg_codeintel; run with `zig build bench` at the repo root.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_codeintel = @import("zg_codeintel");
const zg_syntax = @import("zg_syntax");
const zg_editor = @import("zg_editor");
const zg_lsp = @import("zg_lsp");
const bench = zg_core.bench;
const State = bench.State;
const Registry = zg_codeintel.registry.Registry;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("lsp.sync.didchange_latency: one keystroke on a 10k-line file, edit + frame flush to a didChange body (UI)", {}, didChangeLatency);
    try b.run("codeintel.registry.discover: 6 builtin servers, 6-entry PATH, cold cache", {}, discover);
    try b.run("codeintel.semtok.decode_200k: full result, 20k lines x 10 tokens", {}, decode200k);
    // The fixture is built once, outside the measured calls.
    var fx: DiagFixture = undefined;
    fx.init(std.heap.smp_allocator);
    defer fx.deinit();
    try b.run("codeintel.diag.convert_10k: parse and convert a 10k-diagnostic push (worker)", &fx, diagConvert10k);
    try b.run("codeintel.diag.apply_10k: map 10k diagnostics to bytes and publish (UI)", &fx, diagApply10k);
    try b.run("codeintel.position.convert_ascii: position <-> byte, 10k-line doc, lines in order", &fx, positionAscii);
    var wide: WideFixture = undefined;
    wide.init(std.heap.smp_allocator);
    defer wide.deinit();
    var probs: ProblemsFixture = undefined;
    probs.init(std.heap.smp_allocator);
    defer probs.deinit();
    try b.run("codeintel.problems.filter_100k: rebuild the Problems model, 100k diagnostics in 1000 files, text filter", &probs, problemsFilter100k);
    try b.run("codeintel.snippet.expand_2k: parse and expand a 2 KB snippet (stops, choices, variables, a transform)", {}, snippetExpand2k);
    var cfx: CompletionFixture = undefined;
    cfx.init(std.heap.smp_allocator);
    defer cfx.deinit();
    try b.run("codeintel.completion.refilter_20k: score and sort 20k items for a keystroke (full list)", &cfx, completionRefilter20k);
    try b.run("codeintel.completion.arrive_20k: a 20k-item list arrives: sortText order, score and sort", &cfx, completionArrive20k);
    try b.run("codeintel.completion.decode_5mb: parse a 5 MB completion list and apply its defaults (worker)", &cfx, completionDecode5mb);
    var wsfx: WsEditFixture = undefined;
    wsfx.init(std.heap.smp_allocator);
    defer wsfx.deinit();
    try b.run("lsp.wsedit.plan_10k: plan a workspace edit of 10k text edits on a 10k-line open file", &wsfx, wseditPlan10k);
    var afx: AgentFixture = undefined;
    afx.init(std.heap.smp_allocator);
    defer afx.deinit();
    try b.run("lsp.agent.overhead: an agent's lookup without the server: a name 2 lines off in a 10k-line file, plus a qualified name picked from 1000 workspace symbols", &afx, agentOverhead);
    try b.run("codeintel.position.convert_wide: position <-> byte on a 1000-char non-ASCII line (utf-16)", &wide, positionWide);
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

/// One position each way per op, walking the lines in order as results
/// arrive. Budget: < 200 ns.
fn positionAscii(fx: *DiagFixture, s: *State) void {
    var m: zg_codeintel.features.position.Mapper = .{ .gpa = s.allocator(), .tree = &fx.doc.tree, .enc = .utf16 };
    defer m.deinit();
    var acc: u64 = 0;
    for (0..s.iterations()) |i| {
        const line: u32 = @intCast(i % diag_count);
        const off = m.byteOf(.{ .line = line, .character = 20 }) catch unreachable;
        acc +%= (m.positionOf(off + 3) catch unreachable).character;
    }
    bench.doNotOptimizeAway(acc);
}

const WideFixture = struct {
    doc: *Document,

    fn init(fx: *WideFixture, gpa: std.mem.Allocator) void {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        for (0..250) |_| w.writer.writeAll("a\u{e9}\u{4e2d}\u{1F600}") catch unreachable;
        w.writer.writeAll("\n") catch unreachable;
        fx.doc = Document.initBytes(gpa, @enumFromInt(1), w.written()) catch unreachable;
    }

    fn deinit(fx: *WideFixture) void {
        fx.doc.deinit();
    }
};

/// Columns near the end of a long mixed line, each way. Budget: < 2 us.
fn positionWide(fx: *WideFixture, s: *State) void {
    var m: zg_codeintel.features.position.Mapper = .{ .gpa = s.allocator(), .tree = &fx.doc.tree, .enc = .utf16 };
    defer m.deinit();
    var acc: u64 = 0;
    for (0..s.iterations()) |i| {
        const off = m.byteOf(.{ .line = 0, .character = @intCast(1000 + i % 200) }) catch unreachable;
        acc +%= (m.positionOf(off) catch unreachable).character;
    }
    bench.doNotOptimizeAway(acc);
}

/// 100k diagnostics in 1000 files, committed once.
const ProblemsFixture = struct {
    threaded: std.Io.Threaded,
    store: diag.Store,

    fn init(fx: *ProblemsFixture, gpa: std.mem.Allocator) void {
        fx.threaded = .init(gpa, .{});
        fx.store = diag.Store.init(gpa, fx.threaded.io(), .posix) catch unreachable;
        var key: [32]u8 = undefined;
        for (0..1000) |f| {
            const set = diag.Store.Set.create(gpa, .{ .server = 0 }) catch unreachable;
            const a = set.allocator();
            set.diags = a.alloc(diag.Store.Diagnostic, 100) catch unreachable;
            for (set.diags, 0..) |*d, i| d.* = .{
                .start = .{ .line = @intCast(i), .character = 4 },
                .end = .{ .line = @intCast(i), .character = 9 },
                .severity = @enumFromInt(1 + i % 4),
                .message = if (i % 7 == 0) "use of undeclared identifier 'Needle'" else "unused local constant",
                .source = "zls",
            };
            set.finish();
            fx.store.replace(std.fmt.bufPrint(&key, "/w/src/f{d:0>4}.zig", .{f}) catch unreachable, .{ .server = 0 }, set) catch unreachable;
        }
        fx.store.commit();
    }

    fn deinit(fx: *ProblemsFixture) void {
        fx.store.deinit();
        fx.threaded.deinit();
    }
};

/// Typing in the Problems filter: a rebuild per keystroke. Budget:
/// < 16 ms.
fn problemsFilter100k(fx: *ProblemsFixture, s: *State) void {
    var p = diag.Problems.init(s.allocator());
    defer p.deinit();
    for (0..s.iterations()) |i| {
        _ = p.update(&fx.store, .{ .text = if (i % 2 == 0) "needle" else "need" }) catch unreachable;
        bench.doNotOptimizeAway(p.count());
    }
}

/// A 2 KB snippet in the shape completion items send. Budget: < 50 µs
/// for parse plus expand.
fn snippetExpand2k(_: void, s: *State) void {
    const Snippet = zg_codeintel.snippet.Snippet;
    var src: [2048]u8 = undefined;
    var n: usize = 0;
    const unit = "fn ${1:name}(${2:arg}: ${3|u8,u16,u32|}) ${TM_FILENAME_BASE/(.*)/${1:/pascalcase}/} {\n\t$2\n}\n";
    while (n + unit.len <= src.len) : (n += unit.len) @memcpy(src[n..][0..unit.len], unit);
    const Vars = struct {
        fn get(_: ?*anyopaque, name: []const u8, _: std.mem.Allocator) ?[]const u8 {
            return if (std.mem.eql(u8, name, "TM_FILENAME_BASE")) "my_file" else null;
        }
    };
    const gpa = s.allocator();
    var e: Snippet.Expansion = .{};
    defer e.deinit(gpa);
    for (0..s.iterations()) |_| {
        var sn = Snippet.parse(gpa, src[0..n]) catch unreachable;
        defer sn.deinit();
        sn.expand(gpa, .{ .get = Vars.get }, .{ .line_indent = "    ", .indent_unit = "    " }, &e) catch unreachable;
        bench.doNotOptimizeAway(e.stops.items.len);
    }
}

const crank = zg_codeintel.features.completion_rank;

fn identifiers(gpa: std.mem.Allocator, n: usize) [][]u8 {
    const words = gpa.alloc([]u8, n) catch unreachable;
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
    return words;
}

/// 20k items and a 5 MB `CompletionList` (about 25k items with edits,
/// details and documentation), built once.
const CompletionFixture = struct {
    gpa: std.mem.Allocator,
    words: [][]u8,
    items: []crank.Item,
    json: []u8,
    /// Its item order is computed on the first refilter (when a list
    /// arrives), not per keystroke.
    ranker: crank.Ranker,

    fn init(f: *CompletionFixture, gpa: std.mem.Allocator) void {
        f.gpa = gpa;
        f.ranker = crank.Ranker.init(gpa) catch unreachable;
        f.words = identifiers(gpa, 20_000);
        f.items = gpa.alloc(crank.Item, f.words.len) catch unreachable;
        for (f.items, f.words) |*it, w| it.* = .{ .label = w, .sort_text = w, .sort_key = crank.sortKey(w), .filter_text = w, .edit = .{ .insert_text = w } };
        var w: std.Io.Writer.Allocating = .init(gpa);
        w.writer.writeAll("{\"isIncomplete\":false,\"itemDefaults\":{\"editRange\":{\"start\":{\"line\":10,\"character\":4},\"end\":{\"line\":10,\"character\":6}},\"commitCharacters\":[\".\",\"(\"]},\"items\":[") catch unreachable;
        var i: usize = 0;
        while (w.written().len < 5 * 1024 * 1024) : (i += 1) {
            if (i > 0) w.writer.writeByte(',') catch unreachable;
            const word = f.words[i % 1000];
            w.writer.print("{{\"label\":\"{s}{d}\",\"kind\":{d},\"detail\":\"fn {s}(self: *Self, index: usize) !void\",\"documentation\":{{\"kind\":\"markdown\",\"value\":\"Returns the `{s}` of the node at `index`.\"}},\"sortText\":\"{d:0>6}\",\"filterText\":\"{s}\",\"insertTextFormat\":2,\"textEdit\":{{\"range\":{{\"start\":{{\"line\":10,\"character\":4}},\"end\":{{\"line\":10,\"character\":6}}}},\"newText\":\"{s}(${{1:index}})\"}},\"data\":{{\"id\":{d}}}}}", .{ word, i, i % 25 + 1, word, word, i, word, word, i }) catch unreachable;
        }
        w.writer.writeAll("]}") catch unreachable;
        f.json = w.toOwnedSlice() catch unreachable;
    }

    fn deinit(f: *CompletionFixture) void {
        f.ranker.deinit();
        for (f.words) |w| f.gpa.free(w);
        f.gpa.free(f.words);
        f.gpa.free(f.items);
        f.gpa.free(f.json);
    }
};

/// One keystroke on a 20k-item list, scoring every item (after a
/// deletion; extending scores only the survivors). Budget: < 2 ms.
fn completionRefilter20k(f: *CompletionFixture, s: *State) void {
    const r = &f.ranker;
    // No pattern extends the one before: every item is scored.
    const patterns = [_][]const u8{ "ge", "pa", "co", "parN" };
    for (0..s.iterations()) |i| {
        r.refilter(f.items, patterns[i & 3], null) catch unreachable;
        bench.doNotOptimizeAway(r.ranked.items.len);
    }
}

/// A new 20k-item list: its sortText order computed, then filtered.
fn completionArrive20k(f: *CompletionFixture, s: *State) void {
    const r = &f.ranker;
    for (0..s.iterations()) |_| {
        r.reset();
        r.refilter(f.items, "ge", null) catch unreachable;
        bench.doNotOptimizeAway(r.ranked.items.len);
    }
}

/// The 5 MB list parsed as the client's reader does and decoded with its
/// defaults. Budget: < 15 ms.
fn completionDecode5mb(f: *CompletionFixture, s: *State) void {
    const gpa = s.allocator();
    var items: std.ArrayList(crank.Item) = .empty;
    defer items.deinit(gpa);
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const v = std.json.parseFromSliceLeaky(zg_codeintel.features.CompletionService.Result, arena.allocator(), f.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch unreachable;
        items.clearRetainingCapacity();
        _ = crank.decode(gpa, v, 0, &.{}, &items) catch unreachable;
        bench.doNotOptimizeAway(items.items.len);
    }
}

/// A 10k-line open document and a `WorkspaceEdit` renaming a word on
/// every line, built once.
const WsEditFixture = struct {
    gpa: std.mem.Allocator,
    docs: zg_editor.model.api.registry.DocumentRegistry,
    h: zg_editor.model.api.registry.DocHandle,
    edits: []zg_codeintel.edits.plan.Replace,
    text_edits: []zg_lsp.protocol.TextEdit,
    edit: zg_lsp.protocol.WorkspaceEdit,

    fn init(f: *WsEditFixture, gpa: std.mem.Allocator) void {
        f.gpa = gpa;
        f.docs = .init(gpa, .posix);
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        for (0..10_000) |i| text.writer.print("    const value_{d} = compute(value_{d}, 42);\n", .{ i, i }) catch unreachable;
        f.h = f.docs.openFile("/w/big.zig", text.written()) catch unreachable;
        f.text_edits = gpa.alloc(zg_lsp.protocol.TextEdit, 10_000) catch unreachable;
        for (f.text_edits, 0..) |*te, i| {
            const line: u32 = @intCast(i);
            te.* = .{ .range = .{ .start = .{ .line = line, .character = 10 }, .end = .{ .line = line, .character = 15 } }, .newText = "result" };
        }
        f.edits = &.{};
        var changes: std.json.ArrayHashMap([]const zg_lsp.protocol.TextEdit) = .{};
        changes.map.put(gpa, "file:///w/big.zig", f.text_edits) catch unreachable;
        f.edit = .{ .changes = changes };
    }

    fn deinit(f: *WsEditFixture) void {
        f.edit.changes.?.map.deinit(f.gpa);
        f.gpa.free(f.text_edits);
        f.docs.release(f.h);
        f.docs.deinit();
    }
};

const no_fs: zg_codeintel.edits.plan.FileOps = .{ .ctx = undefined, .vtable = &.{
    .kind = struct {
        fn f(_: *anyopaque, _: []const u8) ?zg_codeintel.edits.plan.FileKind {
            return null;
        }
    }.f,
    .read = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return error.FileNotFound;
        }
    }.f,
    .write = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
            return error.AccessDenied;
        }
    }.f,
    .move = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
            return error.AccessDenied;
        }
    }.f,
    .trash = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return error.AccessDenied;
        }
    }.f,
    .restore = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
            return error.AccessDenied;
        }
    }.f,
    .forget = struct {
        fn f(_: *anyopaque, _: []const u8) void {}
    }.f,
} };

/// Plans 10k edits (convert, sort, check, apply to the copy). Budget:
/// 10k edits in < 10 ms.
fn wseditPlan10k(f: *WsEditFixture, s: *State) void {
    for (0..s.iterations()) |_| {
        var p = zg_codeintel.edits.plan.plan(f.gpa, &f.docs, no_fs, &f.edit, .{ .enc = .utf8 }, "rename", null) catch unreachable;
        bench.doNotOptimizeAway(p.steps.len);
        p.deinit();
    }
}

fn didChangeLatency(_: void, s: *State) void {
    const gpa = s.allocator();
    const api = zg_editor.model.api;
    var reg: api.registry.DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..10_000) |i| text.print(gpa, "    const value_{d} = compute(arg_{d}, \"\u{e9}t\u{e9}\");\n", .{ i, i }) catch unreachable;
    const h = reg.openFile("/bench.zig", text.items) catch unreachable;
    defer reg.release(h);
    const Noop = struct {
        fn send(_: *anyopaque, _: []const u8, params: []const u8) anyerror!void {
            bench.doNotOptimizeAway(params.len);
        }
    };
    var dummy: u8 = 0;
    var sink: zg_codeintel.sync.Sink = .init(gpa, .{ .ctx = &dummy, .send = Noop.send });
    defer sink.deinit();
    var sync: api.lsp_sync.LspSync = .init(gpa, &reg, .utf16, .incremental, sink.lspSink());
    defer sync.deinit();
    sync.track(h, "zig") catch unreachable;
    const doc = reg.get(h).?;
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    for (0..s.iterations()) |i| {
        const at = 5000 * 40 + (i % 400);
        var cs = ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = "x" }}) catch unreachable;
        defer cs.deinit();
        doc.applyChangeSet(&cs, .{ .user = 0 }) catch unreachable;
        sync.flush();
    }
}

const AgentFixture = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8),
    doc: *zg_editor.model.document.Document,
    arena: std.heap.ArenaAllocator,
    cands: [1000]zg_codeintel.agent.locate.Candidate,

    fn init(f: *AgentFixture, gpa: std.mem.Allocator) void {
        f.gpa = gpa;
        f.text = .empty;
        for (0..10_000) |i| f.text.print(gpa, "    const value_{d} = compute(arg_{d}, other_{d});\n", .{ i, i, i }) catch unreachable;
        f.doc = zg_editor.model.document.Document.initBytes(gpa, @enumFromInt(1), f.text.items) catch unreachable;
        f.arena = .init(gpa);
        const a = f.arena.allocator();
        for (&f.cands, 0..) |*c, i| c.* = .{
            .name = if (i % 10 == 0) "init" else std.fmt.allocPrint(a, "init_{d}", .{i}) catch unreachable,
            .container = std.fmt.allocPrint(a, "mod_{d}.Type_{d}", .{ i / 7, i }) catch unreachable,
            .uri = std.fmt.allocPrint(a, "file:///w/src/mod_{d}/type_{d}.zig", .{ i / 7, i }) catch unreachable,
        };
    }

    fn deinit(f: *AgentFixture) void {
        f.arena.deinit();
        f.doc.deinit();
        f.text.deinit(f.gpa);
    }
};

/// What CodeIntel spends besides the server round trip (budget: 2 ms).
fn agentOverhead(f: *AgentFixture, s: *State) void {
    const gpa = s.allocator();
    const locate = zg_codeintel.agent.locate;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..s.iterations()) |i| {
        _ = arena.reset(.retain_capacity);
        var m: zg_codeintel.features.position.Mapper = .{ .gpa = gpa, .tree = &f.doc.tree, .enc = .utf16 };
        defer m.deinit();
        const line: u32 = @intCast(1000 + i % 8000);
        const name = std.fmt.allocPrint(a, "other_{d}", .{line + 1}) catch unreachable;
        const found = locate.inDocument(&m, .{ .name_on_line = .{ .path = "/w/a.zig", .line = line, .name = name } }) catch unreachable;
        bench.doNotOptimizeAway(found);
        const p = locate.pick(a, &f.cands, "mod_42.Type_300.init") catch unreachable;
        bench.doNotOptimizeAway(p);
    }
}
