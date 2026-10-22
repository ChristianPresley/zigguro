const std = @import("std");
const zg_core = @import("zg_core");
const protocol = @import("../gen/protocol.zig");
const caps = @import("caps.zig");
const client_capabilities = @import("client_capabilities.zig");
const doc_selector = @import("doc_selector.zig");
const testing = std.testing;
const Feature = caps.Feature;

fn capsJson(arena: std.mem.Allocator, enabled: caps.EnabledFeatures, opts: client_capabilities.CapOpts) ![]const u8 {
    const cc = try client_capabilities.buildClientCapabilities(arena, enabled, opts);
    return std.json.Stringify.valueAlloc(arena, cc, .{ .whitespace = .indent_2 });
}

test "caps: client capabilities golden" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = try capsJson(arena.allocator(), .initFull(), .{});
    // zg_core's golden helper defaults to zg_core's own package root.
    try zg_core.testkit.golden.expectGoldenOpts(testing.io, @src(), "all_features", json, .{ .root = @import("zg_options").package_root });
    // Byte-stable.
    try testing.expectEqualStrings(json, try capsJson(arena.allocator(), .initFull(), .{}));
    // And it parses back as ClientCapabilities.
    _ = try std.json.parseFromSliceLeaky(protocol.ClientCapabilities, arena.allocator(), json, .{});
}

test "caps: feature gating removes disabled services and >since_max entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var only_hover: caps.EnabledFeatures = .initEmpty();
    only_hover.insert(.hover);
    const cc = try client_capabilities.buildClientCapabilities(a, only_hover, .{});
    const td = cc.textDocument.?;
    try testing.expect(td.hover != null);
    try testing.expect(td.completion == null);
    try testing.expect(td.semanticTokens == null);
    try testing.expect(td.rename == null);
    try testing.expect(cc.workspace.?.symbol == null);
    try testing.expect(cc.workspace.?.inlayHint == null);
    // Base capabilities stay.
    try testing.expect(td.synchronization != null);
    try testing.expect(td.publishDiagnostics != null);
    try testing.expect(cc.workspace.?.workspaceEdit != null);
    try testing.expect(cc.window.?.workDoneProgress.?);

    // Rename without prepare.
    var rename: caps.EnabledFeatures = .initEmpty();
    rename.insert(.rename);
    const r = try client_capabilities.buildClientCapabilities(a, rename, .{});
    try testing.expect(r.textDocument.?.rename.?.prepareSupport == null);

    // since_max 3.16: no inlay hints (3.17), no pull diagnostics (3.17),
    // and none of the 3.18 additions.
    const old = try client_capabilities.buildClientCapabilities(a, .initFull(), .{ .since_max = "3.16.0" });
    try testing.expect(old.textDocument.?.inlayHint == null);
    try testing.expect(old.textDocument.?.diagnostic == null);
    try testing.expect(old.textDocument.?.typeHierarchy == null);
    try testing.expect(old.textDocument.?.semanticTokens != null); // 3.16
    try testing.expect(old.textDocument.?.filters == null);
    try testing.expect(old.workspace.?.textDocumentContent == null);
    try testing.expect(old.workspace.?.workspaceEdit.?.snippetEditSupport == null);
    try testing.expect(old.textDocument.?.rangeFormatting.?.rangesSupport == null);

    const v317 = try client_capabilities.buildClientCapabilities(a, .initFull(), .{ .since_max = "3.17.0" });
    try testing.expect(v317.textDocument.?.inlayHint != null);
    try testing.expect(v317.textDocument.?.diagnostic.?.markupMessageSupport == null);

    // utf-32 only on request.
    try testing.expectEqual(@as(usize, 2), old.general.?.positionEncodings.?.len);
    const u32cc = try client_capabilities.buildClientCapabilities(a, .initEmpty(), .{ .offer_utf32 = true });
    try testing.expectEqual(@as(usize, 3), u32cc.general.?.positionEncodings.?.len);
}

test "caps: versionLe" {
    try testing.expect(client_capabilities.versionLe("3.16.0", "3.17.0"));
    try testing.expect(client_capabilities.versionLe("3.17.0", "3.17.0"));
    try testing.expect(!client_capabilities.versionLe("3.18.0", "3.17.0"));
    try testing.expect(client_capabilities.versionLe("3.9", "3.10.0"));
}

fn serverCaps(arena: std.mem.Allocator, json: []const u8) !caps.ServerCaps {
    const sc = try std.json.parseFromSliceLeaky(protocol.ServerCapabilities, arena, json, .{ .ignore_unknown_fields = true });
    return caps.ServerCaps.fromInitializeResult(testing.allocator, &sc, .{ .roots = &.{"/ws"}, .case_insensitive = false });
}

const zig_doc: doc_selector.DocMatch = .{ .language_id = "zig", .scheme = "file", .path = "/ws/src/main.zig" };
const md_doc: doc_selector.DocMatch = .{ .language_id = "markdown", .scheme = "file", .path = "/ws/README.md" };

test "caps: normalize bool|Options and textDocumentSync forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var c = try serverCaps(a,
            \\{"textDocumentSync": 2, "hoverProvider": true, "definitionProvider": false,
            \\ "renameProvider": {"prepareProvider": true},
            \\ "completionProvider": {"triggerCharacters": [".", "@", "→"], "resolveProvider": true},
            \\ "signatureHelpProvider": {"triggerCharacters": ["("], "retriggerCharacters": [","]},
            \\ "semanticTokensProvider": {"legend": {"tokenTypes": [], "tokenModifiers": []}, "full": {"delta": true}, "range": false},
            \\ "documentRangeFormattingProvider": {"rangesSupport": true},
            \\ "diagnosticProvider": {"interFileDependencies": false, "workspaceDiagnostics": true},
            \\ "executeCommandProvider": {"commands": ["zls.fix"]},
            \\ "workspace": {"fileOperations": {"willRename": {"filters": [{"pattern": {"glob": "**/*.zig"}}]}}}}
        );
        defer c.deinit();
        try testing.expectEqual(protocol.TextDocumentSyncKind.Incremental, c.sync_kind);
        try testing.expect(c.open_close and c.save and !c.save_include_text);
        try testing.expect(c.supports(.hover, zig_doc));
        try testing.expect(!c.supports(.definition, zig_doc));
        try testing.expect(c.supports(.rename, zig_doc) and c.supports(.prepare_rename, null));
        try testing.expect(c.supports(.completion_resolve, null));
        try testing.expectEqualSlices(u21, &.{ '.', '@', '→' }, c.completion_triggers);
        try testing.expectEqualSlices(u21, &.{'('}, c.signature_triggers);
        try testing.expectEqualSlices(u21, &.{','}, c.signature_retriggers);
        try testing.expect(c.supports(.semantic_tokens_full, null) and c.supports(.semantic_tokens_delta, null));
        try testing.expect(!c.supports(.semantic_tokens_range, null));
        try testing.expect(c.supports(.range_formatting, null) and c.supports(.ranges_formatting, null));
        try testing.expect(c.supports(.diagnostic_pull, null) and c.supports(.workspace_diagnostic, null));
        try testing.expect(c.supports(.will_rename_files, null) and !c.supports(.did_rename_files, null));
        try testing.expectEqualStrings("zls.fix", c.options(.execute_command).?.commands[0]);
        try testing.expect(c.options(.semantic_tokens_full).?.full != null);
        try testing.expect(c.options(.hover) != null);
        try testing.expect(c.options(.definition) == null);
        try testing.expect(c.options(.diagnostic_pull).?.workspaceDiagnostics);
    }
    {
        var c = try serverCaps(a,
            \\{"textDocumentSync": {"openClose": true, "change": 1, "save": {"includeText": true}},
            \\ "hoverProvider": {"workDoneProgress": true},
            \\ "codeActionProvider": true}
        );
        defer c.deinit();
        try testing.expectEqual(protocol.TextDocumentSyncKind.Full, c.sync_kind);
        try testing.expect(c.open_close and c.save and c.save_include_text);
        try testing.expect(c.supports(.hover, null));
        try testing.expect(c.options(.code_action).?.codeActionKinds == null);
    }
    {
        var c = try serverCaps(a, "{}");
        defer c.deinit();
        try testing.expectEqual(protocol.TextDocumentSyncKind.None, c.sync_kind);
        try testing.expect(!c.open_close);
        inline for (comptime std.enums.values(Feature)) |f| try testing.expect(!c.supports(f, null));
    }
}

test "caps: static registration options keep their selector" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c = try serverCaps(arena.allocator(),
        \\{"semanticTokensProvider": {"documentSelector": [{"language": "zig"}], "legend": {"tokenTypes": [], "tokenModifiers": []}, "full": true},
        \\ "declarationProvider": {"documentSelector": [{"pattern": "**/*.md"}], "id": "decl"}}
    );
    defer c.deinit();
    try testing.expect(c.supports(.semantic_tokens_full, zig_doc));
    try testing.expect(!c.supports(.semantic_tokens_full, md_doc));
    try testing.expect(c.supports(.declaration, md_doc));
    try testing.expect(!c.supports(.declaration, zig_doc));
    try testing.expect(c.supports(.declaration, null));
}

fn registration(arena: std.mem.Allocator, id: []const u8, method: []const u8, opts: ?[]const u8) !protocol.Registration {
    return .{
        .id = id,
        .method = method,
        .registerOptions = if (opts) |o| try std.json.parseFromSliceLeaky(std.json.Value, arena, o, .{}) else null,
    };
}

test "caps: dynamic registration add/remove affects supports()" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try serverCaps(a, "{\"textDocumentSync\": {\"openClose\": false, \"change\": 0}}");
    defer c.deinit();

    try c.addRegistration(try registration(a, "1", "textDocument/hover", "{\"documentSelector\": [{\"language\": \"zig\"}]}"));
    try c.addRegistration(try registration(a, "2", "textDocument/formatting", null));
    try c.addRegistration(try registration(a, "3", "textDocument/semanticTokens",
        \\{"documentSelector": null, "legend": {"tokenTypes": [], "tokenModifiers": []}, "full": {"delta": true}}
    ));
    try c.addRegistration(try registration(a, "4", "textDocument/didChange", "{\"documentSelector\": [{\"language\": \"zig\"}], \"syncKind\": 2}"));
    try c.addRegistration(try registration(a, "5", "textDocument/didSave", "{\"includeText\": true}"));
    try c.addRegistration(try registration(a, "6", "textDocument/completion", "{\"triggerCharacters\": [\".\"], \"resolveProvider\": true}"));

    try testing.expect(c.supports(.hover, zig_doc));
    try testing.expect(!c.supports(.hover, md_doc));
    try testing.expect(c.supports(.formatting, md_doc));
    try testing.expect(c.supports(.semantic_tokens_full, md_doc) and c.supports(.semantic_tokens_delta, md_doc));
    try testing.expect(!c.supports(.semantic_tokens_range, md_doc));
    try testing.expect(c.supports(.completion, zig_doc) and c.supports(.completion_resolve, zig_doc));
    try testing.expectEqual(protocol.TextDocumentSyncKind.Incremental, c.sync_kind);
    try testing.expect(c.save and c.save_include_text);
    try testing.expectEqualSlices(u21, &.{'.'}, c.completion_triggers);
    try testing.expect(c.registrationOptions(.hover, zig_doc) != null);
    try testing.expect(c.registrationOptions(.hover, md_doc) == null);

    c.removeRegistration("1");
    try testing.expect(!c.supports(.hover, zig_doc));
    c.removeRegistration("nope");
    // Re-registering an id replaces it.
    try c.addRegistration(try registration(a, "2", "textDocument/rangeFormatting", null));
    try testing.expect(!c.supports(.formatting, null));
    try testing.expect(c.supports(.range_formatting, null));
}

test "selector: language/scheme/pattern/RelativePattern table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { sel: []const u8, doc: doc_selector.DocMatch, want: bool, roots: []const []const u8 = &.{"/ws"} };
    const cases = [_]Case{
        .{ .sel = "[{\"language\": \"zig\"}]", .doc = zig_doc, .want = true },
        .{ .sel = "[{\"language\": \"zig\"}]", .doc = md_doc, .want = false },
        .{ .sel = "[{\"scheme\": \"untitled\"}]", .doc = zig_doc, .want = false },
        .{ .sel = "[{\"language\": \"zig\", \"scheme\": \"file\"}]", .doc = zig_doc, .want = true },
        .{ .sel = "[{\"language\": \"zig\", \"scheme\": \"untitled\"}]", .doc = zig_doc, .want = false },
        .{ .sel = "[{\"pattern\": \"**/*.zig\"}]", .doc = zig_doc, .want = true },
        .{ .sel = "[{\"pattern\": \"src/*.zig\"}]", .doc = zig_doc, .want = true },
        .{ .sel = "[{\"pattern\": \"src/*.zig\"}]", .doc = zig_doc, .want = false, .roots = &.{} },
        .{ .sel = "[{\"pattern\": \"**/*.zig\"}]", .doc = .{ .language_id = "zig", .scheme = "untitled", .path = null }, .want = false },
        .{ .sel = "[{\"language\": \"markdown\"}, {\"pattern\": \"**/*.zig\"}]", .doc = zig_doc, .want = true },
        .{ .sel = "[{\"notebook\": \"jupyter-notebook\", \"language\": \"python\"}]", .doc = zig_doc, .want = false },
        .{ .sel = "[{\"pattern\": {\"baseUri\": \"file:///ws/src\", \"pattern\": \"*.zig\"}}]", .doc = zig_doc, .want = true },
        .{ .sel = "[{\"pattern\": {\"baseUri\": \"file:///ws/lib\", \"pattern\": \"*.zig\"}}]", .doc = zig_doc, .want = false },
        .{ .sel = "[{\"pattern\": {\"baseUri\": {\"uri\": \"file:///ws\", \"name\": \"ws\"}, \"pattern\": \"src/**\"}}]", .doc = zig_doc, .want = true },
        .{ .sel = "[]", .doc = zig_doc, .want = false },
    };
    for (cases, 0..) |c, i| {
        const sel = try std.json.parseFromSliceLeaky(protocol.DocumentSelector, a, c.sel, .{ .ignore_unknown_fields = true });
        const got = try doc_selector.matchSelector(testing.allocator, sel, c.doc, c.roots);
        if (got != c.want) {
            std.debug.print("case {d}: {s}\n", .{ i, c.sel });
            return error.TestUnexpectedResult;
        }
    }
}

test "selector: Windows paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc: doc_selector.DocMatch = .{ .language_id = "zig", .scheme = "file", .path = "C:\\ws\\src\\main.zig" };
    const sel = try std.json.parseFromSliceLeaky(protocol.DocumentSelector, a, "[{\"pattern\": \"src/**/*.zig\"}]", .{});
    var cs = try doc_selector.CompiledSelector.init(testing.allocator, sel, &.{"c:\\ws"}, .{});
    defer cs.deinit();
    try testing.expect(cs.matches(doc));
    const sel2 = try std.json.parseFromSliceLeaky(protocol.DocumentSelector, a, "[{\"pattern\": \"**/*.ZIG\"}]", .{});
    var ci = try doc_selector.CompiledSelector.init(testing.allocator, sel2, &.{}, .{ .case_insensitive = true });
    defer ci.deinit();
    try testing.expect(ci.matches(doc));
}

test "caps: supports() with 50 registrations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try serverCaps(a, "{}");
    defer c.deinit();
    for (0..50) |i| {
        const id = try std.fmt.allocPrint(a, "{d}", .{i});
        try c.addRegistration(try registration(a, id, "textDocument/codeLens", "{\"documentSelector\": [{\"language\": \"rust\"}]}"));
    }
    try c.addRegistration(try registration(a, "last", "textDocument/hover", "{\"documentSelector\": [{\"language\": \"zig\"}]}"));
    try testing.expect(c.supports(.hover, zig_doc));
    try testing.expect(!c.supports(.code_lens, zig_doc));
}
