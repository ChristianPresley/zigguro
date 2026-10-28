//! CodeIntel against the fake server: a background document read from
//! disk, qualified names, references, the outline, rename and code
//! actions routed to review, the idle close and a deadline.

const std = @import("std");
const zg_editor = @import("zg_editor");
const CodeIntel = @import("CodeIntel.zig");
const tools = @import("tools.zig");
const BackgroundDocs = @import("background_docs.zig");
const Store = @import("../diagnostics/Store.zig");
const SettleDetector = @import("../diagnostics/settle.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");
const MemFs = @import("../edits/wsedit_test.zig").MemFs;
const Harness = @import("../Manager_test.zig").Harness;

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

const lib_zig =
    \\const Pool = struct {
    \\    pub fn init() Pool {
    \\        return .{};
    \\    }
    \\};
    \\test { _ = Pool.init(); }
    \\
;

const Fx = struct {
    h: Harness,
    st: Store,
    fs: MemFs,
    engine: Engine,
    bg: BackgroundDocs,
    ci: CodeIntel,
    now_ns: i96 = 0,
    review: struct { n: u32 = 0, origin: ?Engine.Origin = null, files: usize = 0 } = .{},

    fn init(f: *Fx) !void {
        try f.h.init("agent.script", &.{});
        try f.h.tmp.dir.writeFile(f.h.rt.io, .{ .sub_path = "lib.zig", .data = lib_zig });
        f.st = try .init(gpa, f.h.rt.io, .native);
        f.fs = .{ .gpa = gpa };
        f.engine = .init(gpa, &f.h.docs, f.fs.ops(), .{});
        f.engine.review = .{ .ctx = f, .submit = submit };
        f.now_ns = 0;
        f.review = .{};
        f.bg = .init(&f.h.mgr, .{ .ctx = f, .read = read, .language = language }, .{ .ctx = f, .now = now }, .{});
        f.ci = .{ .mgr = &f.h.mgr, .store = &f.st, .roots = (&f.h.ws)[0..1], .ui = .{ .ctx = f, .run = runHere }, .engine = &f.engine, .bg = &f.bg };
    }

    fn deinit(f: *Fx) void {
        f.ci.deinit();
        f.bg.deinit();
        f.h.deinit();
        f.engine.deinit();
        f.fs.deinit();
        f.st.deinit();
    }

    /// The test thread is the UI thread; the manager ticks before each
    /// hop, as the app's frame would.
    fn runHere(ctx: *anyopaque, func: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.h.mgr.tick();
        func(arg);
        return true;
    }

    fn read(ctx: *anyopaque, a: Allocator, path: []const u8) anyerror![]u8 {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        return std.Io.Dir.cwd().readFileAlloc(f.h.rt.io, path, a, .limited(1 << 20));
    }

    fn language(_: *anyopaque, path: []const u8, _: []const u8) ?[]const u8 {
        return if (std.mem.endsWith(u8, path, ".zig")) "zig" else null;
    }

    fn now(ctx: ?*anyopaque) i96 {
        const f: *Fx = @ptrCast(@alignCast(ctx.?));
        return f.now_ns;
    }

    fn submit(ctx: *anyopaque, p: *const plan_mod.EditPlan, origin: Engine.Origin) anyerror!u64 {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.review.n += 1;
        f.review.origin = origin;
        f.review.files = p.files.len;
        return 40 + f.review.n;
    }
};

test "codeintel: background document, qualified names, queries, review routing, idle close, deadline" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const io = f.h.rt.io;

    // Not open in the editor: read from disk and opened in the background.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const text = try f.ci.hover(&c, .{ .name_on_line = .{ .path = "lib.zig", .line = 2, .name = "init" } });
        try testing.expectEqualStrings("fn init() Pool", text.?);
        try testing.expectEqual(@as(usize, 1), f.bg.count());
    }
    // A qualified name: the container picks one of two `init`s.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const text = try f.ci.hover(&c, .{ .qualified = "Pool.init" });
        try testing.expectEqualStrings("fn init() Pool", text.?);
    }
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        try testing.expectError(error.Ambiguous, f.ci.hover(&c, .{ .qualified = "init" }));
        try testing.expectEqual(@as(usize, 2), c.candidates.len);
        try testing.expectEqualStrings("Other", c.candidates[0].container.?);
    }
    // References come back sorted.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const r = try f.ci.references(&c, .{ .position = .{ .path = "lib.zig", .line = 6, .column = 17 } }, true, 10);
        try testing.expectEqual(@as(usize, 2), r.total);
        try testing.expectEqual(@as(u32, 1), r.locations[0].range.start.line);
        try testing.expectEqual(@as(u32, 5), r.locations[1].range.start.line);
        try testing.expect(std.mem.endsWith(u8, r.locations[0].path, "/lib.zig"));
    }
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const syms = try f.ci.documentSymbols(&c, "lib.zig", 4);
        try testing.expectEqual(@as(usize, 2), syms.len);
        try testing.expectEqualStrings("init", syms[1].name);
        try testing.expectEqual(@as(u8, 1), syms[1].depth);
        try testing.expectEqualStrings("fn () Pool", syms[1].detail.?);
    }
    // Rename: a preview changes nothing; apply goes to review as the agent's.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const ref: CodeIntel.SymbolRef = .{ .name_on_line = .{ .path = "lib.zig", .line = 2, .name = "init" } };
        const sum = try f.ci.renamePreview(&c, ref, "create");
        try testing.expectEqual(@as(usize, 1), sum.files.len);
        try testing.expectEqual(@as(usize, 2), sum.edits);
        try testing.expectEqual(@as(u32, 0), f.review.n);
        // Through the tool: the changeset comes back with the result.
        var out: tools.Output = .init(arena.allocator());
        try testing.expect(try tools.runAs(&f.ci, 4, io, arena.allocator(), "lsp_rename_apply", "{\"path\": \"lib.zig\", \"line\": 2, \"name\": \"init\", \"new_name\": \"create\"}", &out));
        try testing.expectEqual(@as(?u64, 41), out.changeset);
        try testing.expectEqualStrings("Proposed for review as changeset 41: rename to create. Nothing changes until the user accepts it.", out.text.written());
        try testing.expectEqual(Engine.Origin{ .agent = 4 }, f.review.origin.?);
    }
    // Waiting on a file no server reports for (no driver here): said at
    // once, with the state as structured content.
    {
        var sd: SettleDetector = .init(gpa, io, &f.st, .{});
        defer sd.deinit();
        f.ci.settle = &sd;
        defer f.ci.settle = null;
        var out: tools.Output = .init(arena.allocator());
        const ok = try tools.runAs(&f.ci, 4, io, arena.allocator(), "lsp_wait_for_diagnostics", "{\"paths\": [\"lib.zig\"], \"timeout_ms\": 500}", &out);
        try testing.expectEqualStrings("No errors or warnings in lib.zig.\nNo language server checks lib.zig, and there is no check task to run.", out.text.written());
        // (`waited_ms` is the real time it took.)
        try testing.expect(std.mem.startsWith(u8, out.status.?, "{\"settled\":true,\"heuristic\":false,\"reason\":\"no_server\",\"errors\":0,\"warnings\":0,\"waited_ms\":"));
        try testing.expect(std.mem.endsWith(u8, out.status.?, ",\"build\":null}"));
        try testing.expect(ok);
    }
    // Code actions: preferred first, disabled last; commands are refused;
    // an action without an edit is resolved first.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const acts = try f.ci.codeActions(&c, "lib.zig", .{ 2, 2 });
        try testing.expectEqual(@as(usize, 4), acts.len);
        try testing.expectEqualStrings("Make it const", acts[0].title);
        try testing.expect(acts[0].preferred);
        try testing.expect(acts[3].disabled != null);
        const by = struct {
            fn title(list: []const CodeIntel.ActionSummary, t: []const u8) u32 {
                for (list) |a| if (std.mem.eql(u8, a.title, t)) return a.id;
                unreachable;
            }
        };
        try testing.expectEqual(@as(u64, 42), try f.ci.applyCodeAction(&c, by.title(acts, "Make it const"), 4));
        try testing.expectError(error.Refused, f.ci.applyCodeAction(&c, by.title(acts, "Run"), 4));
        try testing.expectError(error.Refused, f.ci.applyCodeAction(&c, by.title(acts, "Inline"), 4));
        try testing.expectEqual(@as(u64, 43), try f.ci.applyCodeAction(&c, by.title(acts, "Later"), 4));
        try testing.expectError(error.NotFound, f.ci.applyCodeAction(&c, 999, 4));
        try testing.expectEqual(@as(u32, 3), f.review.n);
    }
    // Callers, breadth first, listed depth first; a recursive call is
    // listed once more but not expanded.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        const nodes = try f.ci.callHierarchy(&c, .{ .name_on_line = .{ .path = "lib.zig", .line = 2, .name = "init" } }, .incoming, 3, 50);
        try testing.expectEqual(@as(usize, 3), nodes.len);
        try testing.expectEqualStrings("init", nodes[0].name);
        try testing.expectEqualStrings("test", nodes[1].name);
        try testing.expectEqual(@as(u8, 1), nodes[1].depth);
        try testing.expectEqual(@as(u32, 1), nodes[1].calls);
        try testing.expectEqual(@as(u32, 2), nodes[2].calls);
        try testing.expect(nodes[2].repeated and !nodes[1].repeated);
    }
    // Outside the workspace: refused before anything is opened.
    {
        var c: CodeIntel.Call = .init(io, arena.allocator());
        try testing.expectError(error.OutsideWorkspace, f.ci.hover(&c, .{ .position = .{ .path = "/etc/passwd", .line = 1 } }));
        try testing.expectError(error.OutsideWorkspace, f.ci.hover(&c, .{ .position = .{ .path = "../x.zig", .line = 1 } }));
        try testing.expectError(error.NotFound, f.ci.hover(&c, .{ .position = .{ .path = "nope.zig", .line = 1 } }));
    }
    // Idle for 30 s: closed (didClose).
    f.now_ns += std.time.ns_per_s * 29;
    try testing.expectEqual(@as(usize, 0), f.bg.sweep());
    f.now_ns += std.time.ns_per_s * 1;
    try testing.expectEqual(@as(usize, 1), f.bg.sweep());
    try testing.expect(try f.h.docs.findFile(try std.fs.path.join(arena.allocator(), &.{ f.h.ws, "lib.zig" })) == null);
    // A server slower than the deadline.
    {
        f.ci.timeout = .fromMilliseconds(400);
        var c: CodeIntel.Call = .init(io, arena.allocator());
        try testing.expectError(error.Timeout, f.ci.hover(&c, .{ .position = .{ .path = "lib.zig", .line = 1 } }));
    }
}
