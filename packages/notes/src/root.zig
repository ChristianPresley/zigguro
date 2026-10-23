//! zg_notes: the notes vault (E08.F06, E08.F07): frontmatter, note
//! metadata extraction, the vault-wide link/tag/property index, note
//! search, link-preserving renames, daily notes and templates, and the
//! agent tools over them. Headless: the app and `zg` build UI on top.

const std = @import("std");

/// YAML-subset frontmatter parser (E08.F06.S01.T03).
pub const frontmatter = @import("zg_frontmatter").frontmatter;
/// Byte-preserving property writer (E08.F06.S01.T03).
pub const fm_writer = @import("zg_frontmatter").fm_writer;
/// Vault configuration and detection (E08.F06.S01.T01).
pub const vault = @import("vault/vault.zig");
/// Per-note metadata types.
pub const note = @import("vault/note.zig");
/// Inline tag rules.
pub const tags = @import("vault/tags.zig");
/// The note extractor.
pub const extract_mod = @import("vault/extract.zig");
/// See `extract_mod.extract`.
pub const extract = extract_mod.extract;
pub const Vault = vault.Vault;
pub const VaultConfig = vault.VaultConfig;
pub const VaultId = vault.VaultId;
pub const NoteMeta = note.NoteMeta;
pub const Link = note.Link;
pub const FileId = note.FileId;
/// The vault-wide link/tag/property index (E08.F06.S01.T02).
pub const index = struct {
    pub const note_index = @import("index/note_index.zig");
    pub const names = @import("index/names.zig");
    pub const tag_tree = @import("index/tag_tree.zig");
    pub const properties = @import("index/properties.zig");
    pub const persist = @import("index/persist.zig");
    pub const fuzzy = @import("index/fuzzy.zig");
    pub const mentions = @import("index/mentions.zig");
};
/// Note search (E08.F06.S03.T01).
pub const search = struct {
    pub const tokenize = @import("search/tokenize.zig");
    pub const postings = @import("search/postings.zig");
    pub const bm25 = @import("search/bm25.zig");
    pub const query = @import("search/query.zig");
    pub const exec = @import("search/exec.zig");
    pub const snippets = @import("search/snippets.zig");
    pub const retriever = @import("search/retriever.zig");
    pub const search_index = @import("search/search_index.zig");
    pub const SearchIndex = search_index.SearchIndex;
    pub const QueryAst = query.QueryAst;
    pub const parseQuery = query.parseQuery;
    pub const Retriever = retriever.Retriever;
    pub const Scored = retriever.Scored;
    pub const bm25Retriever = retriever.bm25Retriever;
    pub const hybrid = retriever.hybrid;
    pub const run = exec.search;
};
/// Link-preserving renames and heading renames (E08.F06.S02.T01).
pub const refactor = struct {
    pub const rename = @import("refactor/rename.zig");
    pub const link_text = @import("refactor/link_text.zig");
    pub const heading_rename = @import("refactor/heading_rename.zig");
    pub const planMoves = rename.planMoves;
    pub const planHeadingRename = heading_rename.planHeadingRename;
};
/// Daily notes and templates (E08.F07.S02.T01).
pub const daily = struct {
    pub const datefmt = @import("daily/datefmt.zig");
    pub const localtime = @import("daily/localtime.zig");
    pub const templates = @import("daily/templates.zig");
    pub const notes = @import("daily/daily.zig");
    pub const commands = @import("daily/commands.zig");
    pub const LocalTz = localtime.LocalTz;
    pub const NotesCtx = commands.NotesCtx;
    pub const renderTemplate = templates.renderTemplate;
    pub const listDailyNotes = notes.listDailyNotes;
};
/// Editor language features for notes (E08.F06.S02.T02): completion,
/// hover previews, link navigation and diagnostics.
pub const lang = struct {
    pub const context = @import("lang/context.zig");
    pub const completion = @import("lang/completion.zig");
    pub const hover = @import("lang/hover.zig");
    pub const link_nav = @import("lang/link_nav.zig");
    pub const diagnostics = @import("lang/diagnostics.zig");
};
/// Agent tools and MCP resources over the vault (E08.F08.S02.T01).
pub const ai = struct {
    pub const tools = @import("ai/tools.zig");
    pub const edits = @import("ai/edits.zig");
    pub const resources = @import("ai/resources.zig");
    pub const ToolExporter = tools.ToolExporter;
    pub const ResourceAdapter = resources.ResourceAdapter;
};
pub const NoteIndex = index.note_index.NoteIndex;
pub const IndexView = index.note_index.IndexView;
/// Synthetic notes for tests and benches.
pub const testing = struct {
    pub const gen = @import("testing/gen.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("vault/frontmatter_test.zig");
    _ = @import("vault/fm_writer_test.zig");
    _ = @import("vault/extract_test.zig");
    _ = @import("index/note_index_test.zig");
    _ = @import("search/query_test.zig");
    _ = @import("search/exec_test.zig");
    _ = @import("refactor/rename_test.zig");
    _ = @import("daily/daily_test.zig");
    _ = @import("ai/tools_test.zig");
    _ = @import("lang/lang_test.zig");
}
