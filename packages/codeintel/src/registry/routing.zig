//! Which servers a request goes to when several handle a document
//! (E07.F01.S03.T01). The candidates are a document's servers in registry
//! order, filtered by each definition's feature allow/deny lists and the
//! server's capabilities; then per feature:
//!
//! | Policy | Features |
//! |---|---|
//! | merge results from all | completion, diagnostics (pull), code actions, code lens, document/workspace symbols, references, inlay hints, document links, folding ranges |
//! | the first only | hover, signature help, definition/declaration/type definition/implementation, rename, formatting, semantic tokens, selection ranges, highlights, linked editing, hierarchies, inline values, execute command, file operations |
//!
//! Semantic tokens use one server because overlapping token sets cannot
//! be merged meaningfully; edits (rename, formatting) because two
//! servers' edits would conflict.

const std = @import("std");
const Registry = @import("Registry.zig");
const Feature = Registry.Feature;
const ServerDef = Registry.ServerDef;

pub const Policy = enum { merge_all, first };

pub fn policy(f: Feature) Policy {
    return switch (f) {
        .completion, .completion_resolve, .diagnostic_pull, .workspace_diagnostic, .code_action, .code_lens, .document_symbol, .workspace_symbol, .references, .inlay_hint, .document_link, .folding_range => .merge_all,
        .hover, .signature_help, .definition, .declaration, .type_definition, .implementation, .document_highlight, .formatting, .range_formatting, .ranges_formatting, .on_type_formatting, .rename, .prepare_rename, .selection_range, .semantic_tokens_full, .semantic_tokens_delta, .semantic_tokens_range, .inline_value, .call_hierarchy, .type_hierarchy, .execute_command, .linked_editing_range, .text_document_content, .will_create_files, .will_rename_files, .will_delete_files, .did_create_files, .did_rename_files, .did_delete_files => .first,
    };
}

/// A server that could answer: its definition and whether its
/// capabilities support the feature for the document.
pub fn Candidate(comptime Ctx: type) type {
    return struct { def: *const ServerDef, ctx: Ctx, supports: bool };
}

/// The candidates `f` goes to, in order, written to `out` (a prefix of
/// `out.len`); returns the count.
pub fn select(comptime Ctx: type, f: Feature, candidates: []const Candidate(Ctx), out: []Ctx) usize {
    var n: usize = 0;
    for (candidates) |c| {
        if (!c.supports or !c.def.allows(f)) continue;
        if (n == out.len) break;
        out[n] = c.ctx;
        n += 1;
        if (policy(f) == .first) break;
    }
    return n;
}
