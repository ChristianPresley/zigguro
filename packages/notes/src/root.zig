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
/// Synthetic notes for tests and benches.
pub const testing = struct {
    pub const gen = @import("testing/gen.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("vault/frontmatter_test.zig");
    _ = @import("vault/fm_writer_test.zig");
    _ = @import("vault/extract_test.zig");
}
