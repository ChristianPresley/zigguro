//! Agent tool tests: diagnostics from the store, hover and definition
//! against the fake server, and input checks.

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const tools = @import("tools.zig");
const Store = @import("../diagnostics/Store.zig");
const convert = @import("../diagnostics/convert.zig");
const Harness = @import("../Manager_test.zig").Harness;

const testing = std.testing;
const Io = std.Io;
const protocol = zg_lsp.protocol;

/// The declarations `ToolExporter` uses from zg_ai's foreign contract.
const FakeForeign = struct {
    pub const Kind = enum { lsp, debug, tasks, workspace, notes, scm, mcp };
    pub const ForeignTool = struct {
        name: []const u8,
        description: []const u8,
        input_schema_json: []const u8,
        read_only: bool = false,
        mutates: bool = false,
    };
    pub const Result = struct { json: []const u8, changeset: ?u64 = null };
    pub const Exporter = struct {
        name: []const u8,
        kind: Kind,
        ctx: *anyopaque,
        list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const ForeignTool,
        call: *const fn (ctx: *anyopaque, io: Io, arena: std.mem.Allocator, tool: []const u8, input_json: []const u8) anyerror!Result,
    };
};

/// The test thread is the UI thread.
fn runHere(_: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool {
    f(arg);
    return true;
}

fn lspDiag(line: u32, a: u32, sev: protocol.DiagnosticSeverity, msg: []const u8) protocol.Diagnostic {
    return .{
        .range = .{ .start = .{ .line = line, .character = a }, .end = .{ .line = line, .character = a + 1 } },
        .severity = sev,
        .message = .{ .string = msg },
        .source = "zls",
    };
}

const Call = struct {
    arena: std.heap.ArenaAllocator,
    text: Io.Writer.Allocating,
    ok: bool = false,

    fn init() Call {
        return .{ .arena = .init(testing.allocator), .text = .init(testing.allocator) };
    }
    fn deinit(c: *Call) void {
        c.text.deinit();
        c.arena.deinit();
    }
    fn run(c: *Call, src: *tools.Source, io: Io, tool: []const u8, json: []const u8) ![]const u8 {
        c.text.clearRetainingCapacity();
        c.ok = try tools.run(src, io, c.arena.allocator(), tool, json, &c.text.writer);
        return c.text.written();
    }
};

test "agent tools: diagnostics for a file and the workspace; paths outside refused" {
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(testing.allocator, rt.io, .posix);
    defer st.deinit();
    const a: Store.Owner = .{ .server = 0 };
    inline for (.{ .{ "/w/src/a.zig", &[_]protocol.Diagnostic{ lspDiag(4, 2, .Error, "expected ';'\nnote"), lspDiag(1, 0, .Warning, "unused"), lspDiag(0, 0, .Hint, "style") } }, .{ "/w/b.zig", &[_]protocol.Diagnostic{lspDiag(9, 0, .Error, "bad")} } }) |x| {
        const s = try Store.Set.create(testing.allocator, a);
        try convert.fromLsp(s, x[1]);
        s.diags[0].code = "E1";
        try st.replace(x[0], a, s);
    }
    st.commit();
    var src: tools.Source = .{ .mgr = undefined, .store = &st, .roots = &.{"/w"}, .ui = .{ .ctx = undefined, .run = runHere } };
    var c: Call = .init();
    defer c.deinit();

    try testing.expectEqualStrings(
        \\1 error, 1 warning:
        \\src/a.zig:2:1: warning: unused [zls]
        \\src/a.zig:5:3: error: expected ';' [zls]
    , try c.run(&src, rt.io, "lsp_diagnostics", "{\"path\": \"src/a.zig\"}"));
    try testing.expect(c.ok);
    try testing.expectEqualStrings(
        \\2 errors, 0 warnings in 2 files:
        \\b.zig:10:1: error: bad [zls E1]
        \\src/a.zig:5:3: error: expected ';' [zls]
    , try c.run(&src, rt.io, "lsp_diagnostics", "{\"min_severity\": \"error\"}"));
    try testing.expectEqualStrings(
        \\2 errors, 1 warning, 1 other in 2 files:
        \\b.zig:10:1: error: bad [zls E1]
        \\... and 3 more (raise limit to see them).
    , try c.run(&src, rt.io, "lsp_diagnostics", "{\"min_severity\": \"hint\", \"limit\": 1}"));
    try testing.expectEqualStrings("No diagnostics for /w/c.zig at warning severity or above. (Only files open in the editor are checked by language servers.)", try c.run(&src, rt.io, "lsp_diagnostics", "{\"path\": \"/w/c.zig\"}"));

    _ = try c.run(&src, rt.io, "lsp_diagnostics", "{\"path\": \"/etc/passwd\"}");
    try testing.expect(!c.ok);
    _ = try c.run(&src, rt.io, "lsp_diagnostics", "{\"path\": \"../x.zig\"}");
    try testing.expect(!c.ok);
    _ = try c.run(&src, rt.io, "lsp_diagnostics", "{\"min_severity\": \"fatal\"}");
    try testing.expect(!c.ok);
    _ = try c.run(&src, rt.io, "lsp_hover", "{\"path\": \"a.zig\"}");
    try testing.expect(!c.ok);

    // The exporter lists three read-only tools.
    var x: tools.ToolExporter(FakeForeign) = .{ .src = src };
    const e = x.exporter();
    const ts = try e.list(e.ctx, c.arena.allocator());
    try testing.expectEqual(@as(usize, 3), ts.len);
    for (ts) |t| try testing.expect(t.read_only and !t.mutates);
    const r = try e.call(e.ctx, rt.io, c.arena.allocator(), "lsp_diagnostics", "{\"path\": \"/nope\"}");
    try testing.expect(std.mem.indexOf(u8, r.json, "\"isError\":true") != null);
}

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.sync.?.isTracked(s.docs.items[0])) return true;
    return false;
}

test "agent tools: hover by name one line off, definition by column, no answer" {
    var h: Harness = undefined;
    try h.init("tools.script", &.{});
    defer h.deinit();
    var st = try Store.init(testing.allocator, h.rt.io, .native);
    defer st.deinit();
    const doc = try h.open("main.zig", "const a = 1;\nconst b: u32 = a;\n");
    defer {
        h.mgr.closeDoc(doc);
        h.docs.release(doc);
    }
    for (0..2000) |_| {
        h.mgr.tick();
        if (running(&h)) break;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    } else return error.Timeout;
    var src: tools.Source = .{ .mgr = &h.mgr, .store = &st, .roots = (&h.ws)[0..1], .ui = .{ .ctx = undefined, .run = runHere } };
    var c: Call = .init();
    defer c.deinit();

    try testing.expectEqualStrings("(found on line 2, not 1)\n```zig\nconst b: u32\n```", try c.run(&src, h.rt.io, "lsp_hover", "{\"path\": \"main.zig\", \"line\": 1, \"name\": \"b\"}"));
    try testing.expectEqualStrings("main.zig:1:7", try c.run(&src, h.rt.io, "lsp_definition", "{\"path\": \"main.zig\", \"line\": 2, \"column\": 16}"));
    try testing.expectEqualStrings("No hover information here.", try c.run(&src, h.rt.io, "lsp_hover", "{\"path\": \"main.zig\", \"line\": 1, \"column\": 1}"));
    // Refusals say why.
    try testing.expect(std.mem.indexOf(u8, try c.run(&src, h.rt.io, "lsp_hover", "{\"path\": \"main.zig\", \"line\": 9}"), "past the end") != null);
    try testing.expect(std.mem.indexOf(u8, try c.run(&src, h.rt.io, "lsp_hover", "{\"path\": \"main.zig\", \"line\": 1, \"name\": \"zzz\"}"), "not on line 1") != null);
    try testing.expect(std.mem.indexOf(u8, try c.run(&src, h.rt.io, "lsp_definition", "{\"path\": \"other.zig\", \"line\": 1}"), "not open in the editor") != null);
}
