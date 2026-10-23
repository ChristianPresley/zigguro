//! zg_notes: the notes vault (E08.F06, E08.F07): frontmatter, note
//! metadata extraction, the vault-wide link/tag/property index, note
//! search, link-preserving renames, daily notes and templates, and the
//! agent tools over them. Headless: the app and `zg` build UI on top.

const std = @import("std");

/// YAML-subset frontmatter parser (E08.F06.S01.T03).
pub const frontmatter = @import("vault/frontmatter.zig");
/// Byte-preserving property writer (E08.F06.S01.T03).
pub const fm_writer = @import("vault/fm_writer.zig");
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
}
