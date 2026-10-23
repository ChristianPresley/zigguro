//! zg_frontmatter: the note frontmatter parser and byte-preserving
//! property writer (E08.F06.S01.T03) as a module of their own, needing only
//! std and zg_core, so packages that keep Markdown files with properties
//! (zg_agents' task files, E13.F03) reuse them without the notes vault.

pub const frontmatter = @import("frontmatter.zig");
pub const fm_writer = @import("fm_writer.zig");
