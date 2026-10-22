//! What a server can do: its `ServerCapabilities` plus dynamic
//! registrations, normalized into one queryable `ServerCaps`.
//!
//! - `boolean | Options` providers become present/absent; providers given
//!   as registration options keep their `documentSelector`.
//! - `textDocumentSync` as a number means open/close, that change kind and
//!   save without text (as VS Code reads it); as options it is taken
//!   field by field.
//! - Registrations are kept by id with their `registerOptions` and
//!   compiled selector. `supports` checks static capabilities first, then
//!   registrations whose selector matches the document. Registrations for
//!   `textDocument/didChange`, `didSave`, `didOpen`/`didClose`,
//!   `completion` and `signatureHelp` also update the sync and trigger
//!   fields.
//!
//! Not thread-safe: the owning `Client` serializes access.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../gen/protocol.zig");
const glob = @import("../proto/glob.zig");
const doc_selector = @import("doc_selector.zig");
const DocMatch = doc_selector.DocMatch;
const CompiledSelector = doc_selector.CompiledSelector;

/// A request family a feature service implements.
pub const Feature = enum {
    completion,
    completion_resolve,
    hover,
    signature_help,
    definition,
    declaration,
    type_definition,
    implementation,
    references,
    document_highlight,
    document_symbol,
    workspace_symbol,
    code_action,
    code_lens,
    document_link,
    formatting,
    range_formatting,
    ranges_formatting,
    on_type_formatting,
    rename,
    prepare_rename,
    folding_range,
    selection_range,
    semantic_tokens_full,
    semantic_tokens_delta,
    semantic_tokens_range,
    inlay_hint,
    inline_value,
    call_hierarchy,
    type_hierarchy,
    diagnostic_pull,
    workspace_diagnostic,
    execute_command,
    linked_editing_range,
    text_document_content,
    will_create_files,
    will_rename_files,
    will_delete_files,
    did_create_files,
    did_rename_files,
    did_delete_files,
};

/// Which services are compiled in and enabled.
pub const EnabledFeatures = std.EnumSet(Feature);

/// A sub-capability that must also be set for the feature.
const Flag = enum { none, resolve, ranges, prepare, sem_full, sem_delta, sem_range, workspace };

const Spec = struct {
    /// The request (or, for `did_*_files`, notification) that carries the
    /// feature.
    method: []const u8,
    flag: Flag = .none,
};

/// The wire method of each feature.
pub fn spec(f: Feature) Spec {
    return switch (f) {
        .completion => .{ .method = "textDocument/completion" },
        .completion_resolve => .{ .method = "textDocument/completion", .flag = .resolve },
        .hover => .{ .method = "textDocument/hover" },
        .signature_help => .{ .method = "textDocument/signatureHelp" },
        .definition => .{ .method = "textDocument/definition" },
        .declaration => .{ .method = "textDocument/declaration" },
        .type_definition => .{ .method = "textDocument/typeDefinition" },
        .implementation => .{ .method = "textDocument/implementation" },
        .references => .{ .method = "textDocument/references" },
        .document_highlight => .{ .method = "textDocument/documentHighlight" },
        .document_symbol => .{ .method = "textDocument/documentSymbol" },
        .workspace_symbol => .{ .method = "workspace/symbol" },
        .code_action => .{ .method = "textDocument/codeAction" },
        .code_lens => .{ .method = "textDocument/codeLens" },
        .document_link => .{ .method = "textDocument/documentLink" },
        .formatting => .{ .method = "textDocument/formatting" },
        .range_formatting => .{ .method = "textDocument/rangeFormatting" },
        .ranges_formatting => .{ .method = "textDocument/rangesFormatting", .flag = .ranges },
        .on_type_formatting => .{ .method = "textDocument/onTypeFormatting" },
        .rename => .{ .method = "textDocument/rename" },
        .prepare_rename => .{ .method = "textDocument/prepareRename", .flag = .prepare },
        .folding_range => .{ .method = "textDocument/foldingRange" },
        .selection_range => .{ .method = "textDocument/selectionRange" },
        .semantic_tokens_full => .{ .method = "textDocument/semanticTokens/full", .flag = .sem_full },
        .semantic_tokens_delta => .{ .method = "textDocument/semanticTokens/full/delta", .flag = .sem_delta },
        .semantic_tokens_range => .{ .method = "textDocument/semanticTokens/range", .flag = .sem_range },
        .inlay_hint => .{ .method = "textDocument/inlayHint" },
        .inline_value => .{ .method = "textDocument/inlineValue" },
        .call_hierarchy => .{ .method = "textDocument/prepareCallHierarchy" },
        .type_hierarchy => .{ .method = "textDocument/prepareTypeHierarchy" },
        .diagnostic_pull => .{ .method = "textDocument/diagnostic" },
        .workspace_diagnostic => .{ .method = "workspace/diagnostic", .flag = .workspace },
        .execute_command => .{ .method = "workspace/executeCommand" },
        .linked_editing_range => .{ .method = "textDocument/linkedEditingRange" },
        .text_document_content => .{ .method = "workspace/textDocumentContent" },
        .will_create_files => .{ .method = "workspace/willCreateFiles" },
        .will_rename_files => .{ .method = "workspace/willRenameFiles" },
        .will_delete_files => .{ .method = "workspace/willDeleteFiles" },
        .did_create_files => .{ .method = "workspace/didCreateFiles" },
        .did_rename_files => .{ .method = "workspace/didRenameFiles" },
        .did_delete_files => .{ .method = "workspace/didDeleteFiles" },
    };
}

/// The method a server registers for `f`. Several features share one
/// registration (`textDocument/semanticTokens`, `textDocument/rangeFormatting`,
/// `textDocument/rename`, `textDocument/diagnostic`).
pub fn registrationMethod(f: Feature) []const u8 {
    return switch (f) {
        .semantic_tokens_full, .semantic_tokens_delta, .semantic_tokens_range => "textDocument/semanticTokens",
        .ranges_formatting => "textDocument/rangeFormatting",
        .prepare_rename => "textDocument/rename",
        .workspace_diagnostic => "textDocument/diagnostic",
        else => spec(f).method,
    };
}

/// The typed static options `ServerCaps.options` returns for `f` (`void`
/// when the feature has no options worth reading).
pub fn FeatureOptions(comptime f: Feature) type {
    return switch (f) {
        .completion, .completion_resolve => protocol.CompletionOptions,
        .signature_help => protocol.SignatureHelpOptions,
        .code_action => protocol.CodeActionOptions,
        .code_lens => protocol.CodeLensOptions,
        .document_link => protocol.DocumentLinkOptions,
        .on_type_formatting => protocol.DocumentOnTypeFormattingOptions,
        .execute_command => protocol.ExecuteCommandOptions,
        .semantic_tokens_full, .semantic_tokens_delta, .semantic_tokens_range => protocol.SemanticTokensOptions,
        .diagnostic_pull, .workspace_diagnostic => protocol.DiagnosticOptions,
        .text_document_content => protocol.TextDocumentContentOptions,
        .will_create_files, .will_rename_files, .will_delete_files, .did_create_files, .did_rename_files, .did_delete_files => protocol.FileOperationRegistrationOptions,
        else => void,
    };
}

pub const Options = struct {
    /// Workspace folder paths, for string patterns in selectors.
    roots: []const []const u8 = &.{},
    /// Match selector globs ignoring ASCII case (Windows).
    case_insensitive: bool = @import("builtin").os.tag == .windows,
};

const Registration = struct {
    id: []const u8,
    method: []const u8,
    options: ?Value,
    selector: ?*CompiledSelector,
    /// Features this registration provides.
    features: EnabledFeatures,
};

pub const ServerCaps = struct {
    gpa: Allocator,
    /// Owns `raw`, registration strings, trigger lists.
    arena: *std.heap.ArenaAllocator,
    opts: Options,
    /// A deep copy of the server's static capabilities.
    raw: protocol.ServerCapabilities,
    static: EnabledFeatures,
    static_selectors: std.EnumArray(Feature, ?*CompiledSelector),
    registrations: std.ArrayList(Registration) = .empty,

    sync_kind: protocol.TextDocumentSyncKind = .None,
    open_close: bool = false,
    save: bool = false,
    save_include_text: bool = false,
    completion_triggers: []const u21 = &.{},
    signature_triggers: []const u21 = &.{},
    signature_retriggers: []const u21 = &.{},

    /// Normalizes `r` (copied; `r` may be freed afterwards).
    pub fn fromInitializeResult(gpa: Allocator, r: *const protocol.ServerCapabilities, opts: Options) !ServerCaps {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        const opts_copy: Options = .{ .roots = try dupeStrings(a, opts.roots), .case_insensitive = opts.case_insensitive };
        // Deep copy through JSON: the generated types own no memory.
        const text = try std.json.Stringify.valueAlloc(gpa, r.*, .{});
        defer gpa.free(text);
        const raw = try std.json.parseFromSliceLeaky(protocol.ServerCapabilities, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        var c: ServerCaps = .{
            .gpa = gpa,
            .arena = arena,
            .opts = opts_copy,
            .raw = raw,
            .static = .initEmpty(),
            .static_selectors = .initFill(null),
        };
        errdefer c.deinitSelectors();
        try c.readStatic();
        return c;
    }

    pub fn deinit(c: *ServerCaps) void {
        c.deinitSelectors();
        c.registrations.deinit(c.gpa);
        c.arena.deinit();
        c.gpa.destroy(c.arena);
        c.* = undefined;
    }

    fn deinitSelectors(c: *ServerCaps) void {
        for (&c.static_selectors.values) |*s| if (s.*) |sel| {
            sel.deinit();
            s.* = null;
        };
        for (c.registrations.items) |*reg| if (reg.selector) |sel| {
            sel.deinit();
            reg.selector = null;
        };
    }

    fn compileSelector(c: *ServerCaps, sel: protocol.DocumentSelector) !*CompiledSelector {
        const out = try c.arena.allocator().create(CompiledSelector);
        out.* = try CompiledSelector.init(c.gpa, sel, c.opts.roots, .{ .case_insensitive = c.opts.case_insensitive });
        return out;
    }

    fn setStatic(c: *ServerCaps, f: Feature, on: bool, selector: ?protocol.DocumentSelector) !void {
        if (!on) return;
        c.static.insert(f);
        if (selector) |s| c.static_selectors.set(f, try c.compileSelector(s));
    }

    /// Records a `boolean | Options | RegistrationOptions` provider.
    fn provider(c: *ServerCaps, f: Feature, p: anytype) !void {
        const v = p orelse return;
        switch (@typeInfo(@TypeOf(v))) {
            .@"union" => switch (v) {
                inline else => |x| {
                    if (@TypeOf(x) == bool) return c.setStatic(f, x, null);
                    return c.setStatic(f, true, selectorOf(x));
                },
            },
            else => return c.setStatic(f, true, selectorOf(v)),
        }
    }

    fn readStatic(c: *ServerCaps) !void {
        const r = &c.raw;
        const a = c.arena.allocator();
        try c.provider(.completion, r.completionProvider);
        if (r.completionProvider) |cp| {
            try c.setStatic(.completion_resolve, cp.resolveProvider orelse false, null);
            c.completion_triggers = try codepoints(a, cp.triggerCharacters orelse &.{});
        }
        try c.provider(.hover, r.hoverProvider);
        try c.provider(.signature_help, r.signatureHelpProvider);
        if (r.signatureHelpProvider) |sp| {
            c.signature_triggers = try codepoints(a, sp.triggerCharacters orelse &.{});
            c.signature_retriggers = try codepoints(a, sp.retriggerCharacters orelse &.{});
        }
        try c.provider(.definition, r.definitionProvider);
        try c.provider(.declaration, r.declarationProvider);
        try c.provider(.type_definition, r.typeDefinitionProvider);
        try c.provider(.implementation, r.implementationProvider);
        try c.provider(.references, r.referencesProvider);
        try c.provider(.document_highlight, r.documentHighlightProvider);
        try c.provider(.document_symbol, r.documentSymbolProvider);
        try c.provider(.workspace_symbol, r.workspaceSymbolProvider);
        try c.provider(.code_action, r.codeActionProvider);
        try c.provider(.code_lens, r.codeLensProvider);
        try c.provider(.document_link, r.documentLinkProvider);
        try c.provider(.formatting, r.documentFormattingProvider);
        try c.provider(.range_formatting, r.documentRangeFormattingProvider);
        if (r.documentRangeFormattingProvider) |p| switch (p) {
            .boolean => {},
            inline else => |o| try c.setStatic(.ranges_formatting, o.rangesSupport orelse false, null),
        };
        try c.provider(.on_type_formatting, r.documentOnTypeFormattingProvider);
        try c.provider(.rename, r.renameProvider);
        if (r.renameProvider) |p| switch (p) {
            .boolean => {},
            inline else => |o| try c.setStatic(.prepare_rename, o.prepareProvider orelse false, null),
        };
        try c.provider(.folding_range, r.foldingRangeProvider);
        try c.provider(.selection_range, r.selectionRangeProvider);
        if (r.semanticTokensProvider) |p| switch (p) {
            inline else => |o| {
                const sel = selectorOf(o);
                if (o.full) |full| switch (full) {
                    .boolean => |b| try c.setStatic(.semantic_tokens_full, b, sel),
                    inline else => |d| {
                        try c.setStatic(.semantic_tokens_full, true, sel);
                        try c.setStatic(.semantic_tokens_delta, d.delta orelse false, sel);
                    },
                };
                if (o.range) |range| switch (range) {
                    .boolean => |b| try c.setStatic(.semantic_tokens_range, b, sel),
                    else => try c.setStatic(.semantic_tokens_range, true, sel),
                };
            },
        };
        try c.provider(.inlay_hint, r.inlayHintProvider);
        try c.provider(.inline_value, r.inlineValueProvider);
        try c.provider(.call_hierarchy, r.callHierarchyProvider);
        try c.provider(.type_hierarchy, r.typeHierarchyProvider);
        try c.provider(.diagnostic_pull, r.diagnosticProvider);
        if (r.diagnosticProvider) |p| switch (p) {
            inline else => |o| try c.setStatic(.workspace_diagnostic, o.workspaceDiagnostics, selectorOf(o)),
        };
        try c.provider(.execute_command, r.executeCommandProvider);
        try c.provider(.linked_editing_range, r.linkedEditingRangeProvider);
        if (r.workspace) |ws| {
            try c.provider(.text_document_content, ws.textDocumentContent);
            if (ws.fileOperations) |fo| {
                try c.setStatic(.will_create_files, fo.willCreate != null, null);
                try c.setStatic(.will_rename_files, fo.willRename != null, null);
                try c.setStatic(.will_delete_files, fo.willDelete != null, null);
                try c.setStatic(.did_create_files, fo.didCreate != null, null);
                try c.setStatic(.did_rename_files, fo.didRename != null, null);
                try c.setStatic(.did_delete_files, fo.didDelete != null, null);
            }
        }
        if (r.textDocumentSync) |sync| switch (sync) {
            .text_document_sync_kind => |k| {
                c.sync_kind = k;
                c.open_close = true;
                c.save = true;
            },
            .text_document_sync_options => |o| {
                c.open_close = o.openClose orelse false;
                c.sync_kind = o.change orelse .None;
                if (o.save) |s| switch (s) {
                    .boolean => |b| c.save = b,
                    .save_options => |so| {
                        c.save = true;
                        c.save_include_text = so.includeText orelse false;
                    },
                };
            },
        };
    }

    /// Whether the server provides `f` for `doc` (null: for any document).
    pub fn supports(c: *const ServerCaps, f: Feature, doc: ?DocMatch) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var norm: ?DocMatch = null;
        if (c.static.contains(f)) {
            const sel = c.static_selectors.get(f) orelse return true;
            const d = doc orelse return true;
            norm = doc_selector.normalizeDoc(d, &buf);
            if (sel.matchesNormalized(norm.?)) return true;
        }
        for (c.registrations.items) |*reg| {
            if (!reg.features.contains(f)) continue;
            const sel = reg.selector orelse return true;
            const d = doc orelse return true;
            if (norm == null) norm = doc_selector.normalizeDoc(d, &buf);
            if (sel.matchesNormalized(norm.?)) return true;
        }
        return false;
    }

    /// The static options of `f`, if the server declared it statically.
    pub fn options(c: *const ServerCaps, comptime f: Feature) ?FeatureOptions(f) {
        const T = FeatureOptions(f);
        if (!c.static.contains(f)) return null;
        if (T == void) return {};
        const r = &c.raw;
        return switch (f) {
            .completion, .completion_resolve => r.completionProvider,
            .signature_help => r.signatureHelpProvider,
            .code_lens => r.codeLensProvider,
            .document_link => r.documentLinkProvider,
            .on_type_formatting => r.documentOnTypeFormattingProvider,
            .execute_command => r.executeCommandProvider,
            .code_action => switch (r.codeActionProvider.?) {
                .boolean => .{},
                .code_action_options => |o| o,
            },
            .semantic_tokens_full, .semantic_tokens_delta, .semantic_tokens_range => switch (r.semanticTokensProvider.?) {
                inline else => |o| convert(T, o),
            },
            .diagnostic_pull, .workspace_diagnostic => switch (r.diagnosticProvider.?) {
                inline else => |o| convert(T, o),
            },
            .text_document_content => switch (r.workspace.?.textDocumentContent.?) {
                inline else => |o| convert(T, o),
            },
            .will_create_files => r.workspace.?.fileOperations.?.willCreate,
            .will_rename_files => r.workspace.?.fileOperations.?.willRename,
            .will_delete_files => r.workspace.?.fileOperations.?.willDelete,
            .did_create_files => r.workspace.?.fileOperations.?.didCreate,
            .did_rename_files => r.workspace.?.fileOperations.?.didRename,
            .did_delete_files => r.workspace.?.fileOperations.?.didDelete,
            else => unreachable,
        };
    }

    /// The `registerOptions` of the first dynamic registration providing
    /// `f` for `doc`.
    pub fn registrationOptions(c: *const ServerCaps, f: Feature, doc: ?DocMatch) ?Value {
        for (c.registrations.items) |*reg| {
            if (!reg.features.contains(f)) continue;
            if (reg.selector) |sel| if (doc) |d| if (!sel.matches(d)) continue;
            return reg.options;
        }
        return null;
    }

    /// Adds a `client/registerCapability` registration (copied). A repeated
    /// id replaces the earlier registration.
    pub fn addRegistration(c: *ServerCaps, reg: protocol.Registration) !void {
        c.removeRegistration(reg.id);
        const a = c.arena.allocator();
        const options_copy: ?Value = if (reg.registerOptions) |o| try cloneValue(a, o) else null;
        var selector: ?*CompiledSelector = null;
        if (options_copy) |o| if (o == .object) if (o.object.get("documentSelector")) |ds| if (ds != .null) {
            const sel = try std.json.parseFromValueLeaky(protocol.DocumentSelector, a, ds, .{ .ignore_unknown_fields = true });
            selector = try c.compileSelector(sel);
        };
        errdefer if (selector) |s| s.deinit();
        var features: EnabledFeatures = .initEmpty();
        inline for (comptime std.enums.values(Feature)) |f| {
            if (std.mem.eql(u8, reg.method, registrationMethod(f)) and flagSet(spec(f).flag, options_copy)) features.insert(f);
        }
        try c.registrations.append(c.gpa, .{
            .id = try a.dupe(u8, reg.id),
            .method = try a.dupe(u8, reg.method),
            .options = options_copy,
            .selector = selector,
            .features = features,
        });
        try c.applySyncRegistration(reg.method, options_copy);
    }

    fn applySyncRegistration(c: *ServerCaps, method: []const u8, o: ?Value) !void {
        const a = c.arena.allocator();
        const obj = if (o) |v| (if (v == .object) v.object else null) else null;
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            if (obj) |m| if (m.get("syncKind")) |k| if (k == .integer) {
                c.sync_kind = @enumFromInt(@as(u32, @intCast(std.math.clamp(k.integer, 0, 2))));
            };
        } else if (std.mem.eql(u8, method, "textDocument/didOpen") or std.mem.eql(u8, method, "textDocument/didClose")) {
            c.open_close = true;
        } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
            c.save = true;
            if (obj) |m| if (m.get("includeText")) |b| if (b == .bool) {
                c.save_include_text = b.bool;
            };
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (obj) |m| if (m.get("triggerCharacters")) |t| {
                c.completion_triggers = try codepointsValue(a, t);
            };
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            if (obj) |m| {
                if (m.get("triggerCharacters")) |t| c.signature_triggers = try codepointsValue(a, t);
                if (m.get("retriggerCharacters")) |t| c.signature_retriggers = try codepointsValue(a, t);
            }
        }
    }

    /// Removes the registration with `id` (`client/unregisterCapability`).
    /// Sync and trigger fields keep their last value.
    pub fn removeRegistration(c: *ServerCaps, id: []const u8) void {
        for (c.registrations.items, 0..) |*reg, i| {
            if (!std.mem.eql(u8, reg.id, id)) continue;
            if (reg.selector) |s| s.deinit();
            _ = c.registrations.orderedRemove(i);
            return;
        }
    }
};

/// The `documentSelector` of a registration-options struct, if any.
fn selectorOf(x: anytype) ?protocol.DocumentSelector {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "documentSelector")) return null;
    return x.documentSelector;
}

/// Converts `x` to the structurally identical type `T` (e.g. registration
/// options to options): struct fields by name, union variants by tag name.
fn convert(comptime T: type, x: anytype) T {
    const S = @TypeOf(x);
    if (S == T) return x;
    switch (@typeInfo(T)) {
        .optional => |o| return if (x) |v| convert(o.child, v) else null,
        .@"struct" => {
            var out: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |fld| @field(out, fld.name) = convert(fld.type, @field(x, fld.name));
            return out;
        },
        .@"union" => switch (x) {
            inline else => |v, tag| return @unionInit(T, @tagName(tag), convert(@FieldType(T, @tagName(tag)), v)),
        },
        else => return x,
    }
}

fn flagSet(flag: Flag, o: ?Value) bool {
    if (flag == .none) return true;
    const v = o orelse return false;
    if (v != .object) return false;
    const m = v.object;
    const isTrue = struct {
        fn f(x: ?Value) bool {
            const y = x orelse return false;
            return switch (y) {
                .bool => |b| b,
                .null => false,
                else => true,
            };
        }
    }.f;
    return switch (flag) {
        .none => true,
        .resolve => isTrue(m.get("resolveProvider")),
        .ranges => isTrue(m.get("rangesSupport")),
        .prepare => isTrue(m.get("prepareProvider")),
        .sem_full => isTrue(m.get("full")),
        .sem_delta => blk: {
            const full = m.get("full") orelse break :blk false;
            if (full != .object) break :blk false;
            break :blk isTrue(full.object.get("delta"));
        },
        .sem_range => isTrue(m.get("range")),
        .workspace => isTrue(m.get("workspaceDiagnostics")),
    };
}

fn dupeStrings(a: Allocator, xs: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

/// First code point of each trigger string.
fn codepoints(a: Allocator, xs: []const []const u8) ![]const u21 {
    var out: std.ArrayList(u21) = .empty;
    for (xs) |s| {
        if (s.len == 0) continue;
        const len = std.unicode.utf8ByteSequenceLength(s[0]) catch continue;
        if (len > s.len) continue;
        const cp = std.unicode.utf8Decode(s[0..len]) catch continue;
        try out.append(a, cp);
    }
    return out.toOwnedSlice(a);
}

fn codepointsValue(a: Allocator, v: Value) ![]const u21 {
    if (v != .array) return &.{};
    var strs: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |x| if (x == .string) try strs.append(a, x.string);
    return codepoints(a, strs.items);
}

fn cloneValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, obj.count());
            var it = obj.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => v,
    };
}
