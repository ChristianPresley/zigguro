//! The `ClientCapabilities` zigguro advertises in `initialize`.
//!
//! Every feature-specific entry is gated twice: the feature's service must
//! be enabled (`EnabledFeatures`), and the protocol version that introduced
//! its request (`since` in the generated method tables) must not exceed
//! `CapOpts.since_max`. Entries added in 3.18 are gated on `since_max` as
//! well. Base entries (synchronization, push diagnostics, workspace edits,
//! configuration, window and general capabilities) are always sent.
//!
//! The full object is pinned by a golden test, so any change shows up in
//! review.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../gen/protocol.zig");
const caps = @import("caps.zig");
const Feature = caps.Feature;
const EnabledFeatures = caps.EnabledFeatures;

pub const CapOpts = struct {
    /// Newest protocol version to advertise features from.
    since_max: []const u8 = "3.18.0",
    /// Also offer `utf-32` positions (`lsp.offerUtf32`).
    offer_utf32: bool = false,
    /// Version of our markdown renderer, for `general.markdown`.
    markdown_version: []const u8 = "0.1.0",
    /// Semantic token legend (default: the standard LSP types and
    /// modifiers; E05 supplies the real legend).
    token_types: ?[]const []const u8 = null,
    token_modifiers: ?[]const []const u8 = null,
    /// Advertise `dynamicRegistration` wherever the protocol allows it.
    dynamic_registration: bool = true,
};

/// Requests to retry when they fail with ContentModified.
pub const retry_on_content_modified = [_][]const u8{
    "textDocument/semanticTokens/full",
    "textDocument/semanticTokens/full/delta",
    "textDocument/semanticTokens/range",
    "textDocument/inlayHint",
    "textDocument/documentHighlight",
};

/// Whether version `a` <= `b` (dotted decimal, missing parts are zero).
pub fn versionLe(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    for (0..3) |_| {
        const x = std.fmt.parseInt(u32, ia.next() orelse "0", 10) catch 0;
        const y = std.fmt.parseInt(u32, ib.next() orelse "0", 10) catch 0;
        if (x != y) return x < y;
    }
    return true;
}

/// The protocol version that introduced `f`'s request, if recorded.
pub fn featureSince(comptime f: Feature) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const name = comptime caps.spec(f).method;
    inline for (@typeInfo(protocol.Method).@"enum".fields) |fld| {
        if (comptime std.mem.eql(u8, fld.name, name)) return protocol.RequestInfo(@field(protocol.Method, fld.name)).since;
    }
    inline for (@typeInfo(protocol.NotificationMethod).@"enum".fields) |fld| {
        if (comptime std.mem.eql(u8, fld.name, name)) return protocol.NotificationInfo(@field(protocol.NotificationMethod, fld.name)).since;
    }
    @compileError("no method " ++ name);
}

fn wireValues(comptime OE: type) []const []const u8 {
    return @FieldType(OE, "known").json_values[0..];
}

/// Builds the capabilities object in `arena`.
pub fn buildClientCapabilities(arena: Allocator, enabled: EnabledFeatures, opts: CapOpts) !protocol.ClientCapabilities {
    // Which features are on, after version gating.
    var on: EnabledFeatures = .initEmpty();
    inline for (comptime std.enums.values(Feature)) |f| {
        const since = comptime featureSince(f) orelse "3.0.0";
        if (enabled.contains(f) and versionLe(since, opts.since_max)) on.insert(f);
    }
    const v318 = versionLe("3.18.0", opts.since_max);
    const dyn: ?bool = if (opts.dynamic_registration) true else null;
    const markup = try arena.dupe(protocol.MarkupKind, &.{ .Markdown, .PlainText });

    var encodings: std.ArrayList(protocol.PositionEncodingKind) = .empty;
    try encodings.append(arena, .{ .known = .UTF8 });
    try encodings.append(arena, .{ .known = .UTF16 });
    if (opts.offer_utf32) try encodings.append(arena, .{ .known = .UTF32 });

    const symbol_kinds = try arena.alloc(protocol.SymbolKind, 26);
    for (symbol_kinds, 1..) |*k, i| k.* = @enumFromInt(i);
    const completion_kinds = try arena.alloc(protocol.CompletionItemKind, 25);
    for (completion_kinds, 1..) |*k, i| k.* = @enumFromInt(i);

    const any_sem = on.contains(.semantic_tokens_full) or on.contains(.semantic_tokens_range);
    const any_file_op = on.contains(.will_create_files) or on.contains(.will_rename_files) or on.contains(.will_delete_files) or
        on.contains(.did_create_files) or on.contains(.did_rename_files) or on.contains(.did_delete_files);
    const refresh = struct {
        fn f(x: bool) ?bool {
            return if (x) true else null;
        }
    }.f;

    const workspace: protocol.WorkspaceClientCapabilities = .{
        .applyEdit = true,
        .workspaceEdit = .{
            .documentChanges = true,
            .resourceOperations = try arena.dupe(protocol.ResourceOperationKind, &.{ .Create, .Rename, .Delete }),
            .failureHandling = .Transactional,
            .normalizesLineEndings = true,
            .changeAnnotationSupport = .{ .groupsOnLabel = true },
            .snippetEditSupport = if (v318) true else null,
        },
        .didChangeConfiguration = .{ .dynamicRegistration = dyn },
        .didChangeWatchedFiles = .{ .dynamicRegistration = dyn, .relativePatternSupport = true },
        .symbol = if (on.contains(.workspace_symbol)) .{
            .dynamicRegistration = dyn,
            .symbolKind = .{ .valueSet = symbol_kinds },
            .tagSupport = .{ .valueSet = try arena.dupe(protocol.SymbolTag, &.{.Deprecated}) },
            .resolveSupport = .{ .properties = try arena.dupe([]const u8, &.{"location.range"}) },
        } else null,
        .executeCommand = if (on.contains(.execute_command)) .{ .dynamicRegistration = dyn } else null,
        .workspaceFolders = true,
        .configuration = true,
        .semanticTokens = if (any_sem) .{ .refreshSupport = true } else null,
        .codeLens = if (on.contains(.code_lens)) .{ .refreshSupport = true } else null,
        .fileOperations = if (any_file_op) .{
            .dynamicRegistration = dyn,
            .didCreate = refresh(on.contains(.did_create_files)),
            .willCreate = refresh(on.contains(.will_create_files)),
            .didRename = refresh(on.contains(.did_rename_files)),
            .willRename = refresh(on.contains(.will_rename_files)),
            .didDelete = refresh(on.contains(.did_delete_files)),
            .willDelete = refresh(on.contains(.will_delete_files)),
        } else null,
        .inlineValue = if (on.contains(.inline_value)) .{ .refreshSupport = true } else null,
        .inlayHint = if (on.contains(.inlay_hint)) .{ .refreshSupport = true } else null,
        .diagnostics = if (on.contains(.diagnostic_pull)) .{ .refreshSupport = true } else null,
        .foldingRange = if (v318 and on.contains(.folding_range)) .{ .refreshSupport = true } else null,
        .textDocumentContent = if (v318 and on.contains(.text_document_content)) .{ .dynamicRegistration = dyn } else null,
    };

    const tags = try arena.dupe(protocol.DiagnosticTag, &.{ .Unnecessary, .Deprecated });
    const text_document: protocol.TextDocumentClientCapabilities = .{
        .synchronization = .{ .dynamicRegistration = dyn, .willSave = false, .willSaveWaitUntil = false, .didSave = true },
        .filters = if (v318) .{ .relativePatternSupport = true } else null,
        .completion = if (on.contains(.completion)) .{
            .dynamicRegistration = dyn,
            .completionItem = .{
                .snippetSupport = true,
                .commitCharactersSupport = true,
                .documentationFormat = markup,
                .deprecatedSupport = true,
                .preselectSupport = true,
                .tagSupport = .{ .valueSet = try arena.dupe(protocol.CompletionItemTag, &.{.Deprecated}) },
                .insertReplaceSupport = true,
                .resolveSupport = if (on.contains(.completion_resolve)) .{
                    .properties = try arena.dupe([]const u8, &.{ "documentation", "detail", "additionalTextEdits" }),
                } else null,
                .insertTextModeSupport = .{ .valueSet = try arena.dupe(protocol.InsertTextMode, &.{ .asIs, .adjustIndentation }) },
                .labelDetailsSupport = true,
            },
            .completionItemKind = .{ .valueSet = completion_kinds },
            .contextSupport = true,
            .completionList = .{
                .itemDefaults = try arena.dupe([]const u8, &.{ "commitCharacters", "editRange", "insertTextFormat", "insertTextMode", "data" }),
            },
        } else null,
        .hover = if (on.contains(.hover)) .{ .dynamicRegistration = dyn, .contentFormat = markup } else null,
        .signatureHelp = if (on.contains(.signature_help)) .{
            .dynamicRegistration = dyn,
            .signatureInformation = .{
                .documentationFormat = markup,
                .parameterInformation = .{ .labelOffsetSupport = true },
                .activeParameterSupport = true,
            },
            .contextSupport = true,
        } else null,
        .declaration = if (on.contains(.declaration)) .{ .dynamicRegistration = dyn, .linkSupport = true } else null,
        .definition = if (on.contains(.definition)) .{ .dynamicRegistration = dyn, .linkSupport = true } else null,
        .typeDefinition = if (on.contains(.type_definition)) .{ .dynamicRegistration = dyn, .linkSupport = true } else null,
        .implementation = if (on.contains(.implementation)) .{ .dynamicRegistration = dyn, .linkSupport = true } else null,
        .references = if (on.contains(.references)) .{ .dynamicRegistration = dyn } else null,
        .documentHighlight = if (on.contains(.document_highlight)) .{ .dynamicRegistration = dyn } else null,
        .documentSymbol = if (on.contains(.document_symbol)) .{
            .dynamicRegistration = dyn,
            .symbolKind = .{ .valueSet = symbol_kinds },
            .hierarchicalDocumentSymbolSupport = true,
            .tagSupport = .{ .valueSet = try arena.dupe(protocol.SymbolTag, &.{.Deprecated}) },
            .labelSupport = true,
        } else null,
        .codeAction = if (on.contains(.code_action)) .{
            .dynamicRegistration = dyn,
            .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = try arena.dupe(protocol.CodeActionKind, &.{
                .{ .known = .Empty },
                .{ .known = .QuickFix },
                .{ .known = .Refactor },
                .{ .known = .RefactorExtract },
                .{ .known = .RefactorInline },
                .{ .known = .RefactorRewrite },
                .{ .known = .Source },
                .{ .known = .SourceOrganizeImports },
                .{ .known = .SourceFixAll },
            }) } },
            .isPreferredSupport = true,
            .disabledSupport = true,
            .dataSupport = true,
            .resolveSupport = .{ .properties = try arena.dupe([]const u8, &.{"edit"}) },
            .honorsChangeAnnotations = true,
        } else null,
        .codeLens = if (on.contains(.code_lens)) .{ .dynamicRegistration = dyn } else null,
        .documentLink = if (on.contains(.document_link)) .{ .dynamicRegistration = dyn, .tooltipSupport = true } else null,
        .formatting = if (on.contains(.formatting)) .{ .dynamicRegistration = dyn } else null,
        .rangeFormatting = if (on.contains(.range_formatting)) .{
            .dynamicRegistration = dyn,
            .rangesSupport = if (v318 and on.contains(.ranges_formatting)) true else null,
        } else null,
        .onTypeFormatting = if (on.contains(.on_type_formatting)) .{ .dynamicRegistration = dyn } else null,
        .rename = if (on.contains(.rename)) .{
            .dynamicRegistration = dyn,
            .prepareSupport = if (on.contains(.prepare_rename)) true else null,
            .prepareSupportDefaultBehavior = if (on.contains(.prepare_rename)) .Identifier else null,
            .honorsChangeAnnotations = true,
        } else null,
        .foldingRange = if (on.contains(.folding_range)) .{
            .dynamicRegistration = dyn,
            .rangeLimit = 5000,
            .lineFoldingOnly = false,
            .foldingRange = .{ .collapsedText = true },
        } else null,
        .selectionRange = if (on.contains(.selection_range)) .{ .dynamicRegistration = dyn } else null,
        .publishDiagnostics = .{
            .relatedInformation = true,
            .tagSupport = .{ .valueSet = tags },
            .codeDescriptionSupport = true,
            .dataSupport = true,
            .versionSupport = true,
        },
        .callHierarchy = if (on.contains(.call_hierarchy)) .{ .dynamicRegistration = dyn } else null,
        .semanticTokens = if (any_sem) .{
            .dynamicRegistration = dyn,
            .requests = .{
                .range = if (on.contains(.semantic_tokens_range)) .{ .boolean = true } else null,
                .full = if (on.contains(.semantic_tokens_full))
                    .{ .client_semantic_tokens_request_full_delta = .{ .delta = on.contains(.semantic_tokens_delta) } }
                else
                    null,
            },
            .tokenTypes = opts.token_types orelse wireValues(protocol.SemanticTokenTypes),
            .tokenModifiers = opts.token_modifiers orelse wireValues(protocol.SemanticTokenModifiers),
            .formats = try arena.dupe(protocol.TokenFormat, &.{.Relative}),
            .overlappingTokenSupport = false,
            .multilineTokenSupport = true,
            .serverCancelSupport = true,
            .augmentsSyntaxTokens = true,
        } else null,
        .linkedEditingRange = if (on.contains(.linked_editing_range)) .{ .dynamicRegistration = dyn } else null,
        .typeHierarchy = if (on.contains(.type_hierarchy)) .{ .dynamicRegistration = dyn } else null,
        .inlineValue = if (on.contains(.inline_value)) .{ .dynamicRegistration = dyn } else null,
        .inlayHint = if (on.contains(.inlay_hint)) .{
            .dynamicRegistration = dyn,
            .resolveSupport = .{ .properties = try arena.dupe([]const u8, &.{ "tooltip", "textEdits", "label.tooltip", "label.location", "label.command" }) },
        } else null,
        .diagnostic = if (on.contains(.diagnostic_pull)) .{
            .dynamicRegistration = dyn,
            .relatedDocumentSupport = true,
            .relatedInformation = true,
            .tagSupport = .{ .valueSet = tags },
            .codeDescriptionSupport = true,
            .dataSupport = true,
            .markupMessageSupport = if (v318) true else null,
        } else null,
    };

    return .{
        .workspace = workspace,
        .textDocument = text_document,
        .window = .{
            .workDoneProgress = true,
            .showMessage = .{ .messageActionItem = .{ .additionalPropertiesSupport = true } },
            .showDocument = .{ .support = true },
        },
        .general = .{
            .staleRequestSupport = .{ .cancel = true, .retryOnContentModified = &retry_on_content_modified },
            .markdown = .{ .parser = "zigguro", .version = opts.markdown_version },
            .positionEncodings = encodings.items,
        },
    };
}
