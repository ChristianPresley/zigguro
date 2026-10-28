//! Tests for the fast completion decoder (`completion_parse.zig`): every
//! input it takes must decode exactly as std.json decodes it, and what it
//! does not take must be `error.Unsupported` (the client then asks
//! std.json).

const std = @import("std");
const testing = std.testing;
const protocol = @import("../gen/protocol.zig");
const completion_parse = @import("completion_parse.zig");

const Result = ?protocol.TextDocumentCompletionResult;

fn viaStd(a: std.mem.Allocator, bytes: []const u8) !Result {
    return std.json.parseFromSliceLeaky(Result, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Both decoders agree on `bytes` (compared as re-encoded JSON).
fn same(bytes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try viaStd(a, bytes);
    const got = try completion_parse.parse(a, bytes);
    try testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(a, want, .{}),
        try std.json.Stringify.valueAlloc(a, got, .{}),
    );
}

fn unsupported(bytes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Unsupported, completion_parse.parse(arena.allocator(), bytes));
}

test "completion_parse: null, arrays and lists" {
    try same("null");
    try same(" null ");
    try same("[]");
    try same("[{\"label\":\"a\"},{\"label\":\"b\",\"kind\":3}]");
    try same("{\"isIncomplete\":true,\"items\":[]}");
    try same("{\"items\":[{\"label\":\"x\"}],\"isIncomplete\":false}");
    try same(" {\n\t\"isIncomplete\" : false ,\r\n \"items\" : [ { \"label\" : \"x\" } ] } ");
}

test "completion_parse: every item field" {
    try same(
        \\[{"label":"print","labelDetails":{"detail":"(fmt)","description":"std.debug"},
        \\"kind":3,"tags":[1],"detail":"fn print() void",
        \\"documentation":{"kind":"markdown","value":"Prints **it**."},
        \\"deprecated":false,"preselect":true,"sortText":"0001","filterText":"print",
        \\"insertText":"print($1)","insertTextFormat":2,"insertTextMode":2,
        \\"textEdit":{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"newText":"print"},
        \\"textEditText":"p",
        \\"additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"const std = @import(\"std\");\n"}],
        \\"commitCharacters":[".","("],
        \\"command":{"title":"Trigger","command":"editor.action.triggerParameterHints","tooltip":"t","arguments":[1,-2,3.5,"s",true,null,{"k":[1e3]}]},
        \\"data":{"id":12345678901234567890,"n":-0,"f":1.25e-3,"nested":[{"a":null}]}}]
    );
}

test "completion_parse: field forms" {
    // Plain documentation, insert/replace edits, nulls everywhere.
    try same("[{\"label\":\"a\",\"documentation\":\"plain\"}]");
    try same("[{\"label\":\"a\",\"documentation\":{\"kind\":\"plaintext\",\"value\":\"\"}}]");
    try same(
        \\[{"label":"a","textEdit":{"newText":"ab","insert":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
        \\"replace":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}}}}]
    );
    try same(
        \\[{"label":"a","labelDetails":null,"kind":null,"tags":null,"detail":null,"documentation":null,
        \\"deprecated":null,"preselect":null,"sortText":null,"filterText":null,"insertText":null,
        \\"insertTextFormat":null,"insertTextMode":null,"textEdit":null,"textEditText":null,
        \\"additionalTextEdits":null,"commitCharacters":null,"command":null,"data":null}]
    );
    try same("[{\"label\":\"a\",\"labelDetails\":{}}]");
    try same("[{\"label\":\"a\",\"kind\":99,\"tags\":[7]}]");
    try same("[{\"label\":\"a\",\"command\":{\"title\":\"t\",\"command\":\"c\",\"arguments\":null}}]");
    try same("[{\"label\":\"a\",\"data\":[]}]");
    try same("[{\"label\":\"a\",\"data\":{}}]");
    try same("[{\"label\":\"a\",\"data\":\"s\"}]");
}

test "completion_parse: escapes" {
    try same("[{\"label\":\"q\\\"b\\\\s\\/n\\nr\\rt\\tb\\bf\\f\"}]");
    try same("[{\"label\":\"\\u00e9\\u4e2d\\ud83d\\ude00 end\"}]");
    try same("[{\"label\":\"plain \xc3\xa9 \xe4\xb8\xad\"}]");
    try same("[{\"label\":\"a\",\"data\":{\"k\\u0041\":\"\\n\"}}]");
}

test "completion_parse: unknown fields are skipped" {
    try same(
        \\{"isIncomplete":false,"extra":{"a":[1,{"b":"]}"}],"c":"\""},"items":[
        \\{"label":"a","x":1,"y":"}","z":[[]],"w":null,"v":true,"u":-1.5e2}]}
    );
    try same("[{\"label\":\"a\",\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":0,\"x\":1},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"\",\"y\":2}}]");
}

test "completion_parse: item defaults and apply kinds" {
    try same(
        \\{"isIncomplete":false,"itemDefaults":{"commitCharacters":["."],
        \\"editRange":{"insert":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
        \\"replace":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}},
        \\"insertTextFormat":2,"insertTextMode":1,"data":{"x":1}},"applyKind":{"commitCharacters":2},"items":[{"label":"a"}]}
    );
    try same("{\"isIncomplete\":false,\"itemDefaults\":null,\"applyKind\":null,\"items\":[]}");
}

test "completion_parse: what it leaves to std.json" {
    // Shapes std.json may take or reject; this decoder declines them.
    try unsupported("[{\"label\":\"a\",\"kind\":\"Function\"}]");
    try unsupported("[{\"label\":\"a\",\"kind\":3.0}]");
    try unsupported("[{\"label\":\"a\",\"kind\":-1}]");
    try unsupported("[{\"label\":\"a\",\"kind\":03}]");
    try unsupported("[{\"label\":\"a\",\"kind\":4294967296}]");
    try unsupported("[{\"label\":\"a\",\"documentation\":{\"kind\":\"html\",\"value\":\"\"}}]");
    // Required fields missing or doubled.
    try unsupported("[{\"kind\":3}]");
    try unsupported("{\"items\":[]}");
    try unsupported("{\"isIncomplete\":false}");
    try unsupported("[{\"label\":\"a\",\"label\":\"b\"}]");
    try unsupported("[{\"label\":\"a\",\"data\":{\"k\":1,\"k\":2}}]");
    try unsupported("[{\"label\":\"a\",\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"line\":1,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"\"}}]");
    // Strings std.json rejects.
    try unsupported("[{\"label\":\"a\nb\"}]");
    try unsupported("[{\"label\":\"\\ud800\"}]");
    try unsupported("[{\"label\":\"\\udc00x\"}]");
    try unsupported("[{\"label\":\"\\x\"}]");
    try unsupported("[{\"label\":\"\xff\"}]");
    // Malformed.
    try unsupported("");
    try unsupported("[");
    try unsupported("[{\"label\":\"a\"}");
    try unsupported("[{\"label\":\"a\"}] x");
    try unsupported("[{\"label\":\"a\"},]");
    try unsupported("[{\"label\":\"a\",\"data\":01}]");
    try unsupported("[{\"label\":\"a\",\"data\":1.}]");
    try unsupported("[{\"label\":\"a\",\"data\":nul}]");
    try unsupported("{\"isIncomplete\":null,\"items\":[]}");
    try unsupported("42");
}

test "completion_parse: random lists match std.json" {
    var prng: std.Random.DefaultPrng = .init(0x571);
    const r = prng.random();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const words = [_][]const u8{ "", "x", "print", "q\"uote", "back\\slash", "new\nline", "tab\t", "\xc3\xa9t\xc3\xa9", "\x01ctl", "\u{1F600}", "/slash" };
    for (0..200) |_| {
        const n = r.uintLessThan(usize, 6);
        const its = try a.alloc(protocol.CompletionItem, n);
        for (its) |*it| {
            const w = struct {
                fn pick(rr: std.Random, ws: []const []const u8) []const u8 {
                    return ws[rr.uintLessThan(usize, ws.len)];
                }
                fn opt(rr: std.Random, ws: []const []const u8) ?[]const u8 {
                    return if (rr.boolean()) pick(rr, ws) else null;
                }
            };
            const pos: protocol.Position = .{ .line = r.int(u32), .character = r.uintLessThan(u32, 200) };
            const rng: protocol.Range = .{ .start = pos, .end = pos };
            it.* = .{
                .label = w.pick(r, &words),
                .kind = if (r.boolean()) @enumFromInt(r.uintLessThan(u32, 30)) else null,
                .detail = w.opt(r, &words),
                .sortText = w.opt(r, &words),
                .filterText = w.opt(r, &words),
                .insertText = w.opt(r, &words),
                .deprecated = if (r.boolean()) r.boolean() else null,
                .documentation = switch (r.uintLessThan(u8, 3)) {
                    0 => null,
                    1 => .{ .string = w.pick(r, &words) },
                    else => .{ .markup_content = .{ .kind = if (r.boolean()) .Markdown else .PlainText, .value = w.pick(r, &words) } },
                },
                .textEdit = switch (r.uintLessThan(u8, 3)) {
                    0 => null,
                    1 => .{ .text_edit = .{ .range = rng, .newText = w.pick(r, &words) } },
                    else => .{ .insert_replace_edit = .{ .newText = w.pick(r, &words), .insert = rng, .replace = rng } },
                },
                .additionalTextEdits = if (r.boolean()) &.{.{ .range = rng, .newText = w.pick(r, &words) }} else null,
                .data = if (r.boolean()) .{ .integer = r.int(i32) } else null,
            };
        }
        const res: Result = if (r.boolean())
            .{ .completion_item_array = its }
        else
            .{ .completion_list = .{ .isIncomplete = r.boolean(), .items = its } };
        const bytes = try std.json.Stringify.valueAlloc(a, res, .{ .whitespace = if (r.boolean()) .indent_2 else .minified });
        try same(bytes);
    }
}
