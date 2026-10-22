//! zg_ignore: git-compatible ignore matching, std only.
//!
//! - `wildmatch`: git's glob dialect (gitignore(5) patterns).
//! - `parseRules` / `RuleList`: one `.gitignore`, `info/exclude` or
//!   `core.excludesFile` parsed into rules with last-match-wins lookup.
//!
//! This module imports nothing but `std` so that zg-git (E09.F07.S02.T02)
//! and zg-scm use the same implementation as the workspace.

/// git's wildmatch glob matcher.
pub const wildmatch = @import("wildmatch.zig");

const gitignore = @import("gitignore.zig");
/// The parsed rules of one ignore file.
pub const RuleList = gitignore.RuleList;
/// One parsed ignore line.
pub const Rule = gitignore.Rule;
/// The rule that decided a lookup.
pub const Hit = gitignore.Hit;
/// The kind of file a rule came from.
pub const Source = gitignore.Source;
/// Parses the bytes of one ignore file into a `RuleList`.
pub const parseRules = gitignore.parseRules;
/// Parses one already-trimmed ignore line.
pub const parseLine = gitignore.parseLine;
/// Builds the lookup indexes of a rule slice.
pub const indexRules = gitignore.index;
/// Whether one rule matches a path (ignoring negation).
pub const ruleMatches = gitignore.ruleMatches;
/// VS Code-style include/exclude globs.
pub const GlobSet = @import("globset.zig").GlobSet;
/// Brace expansion used by `GlobSet`.
pub const expandBraces = @import("globset.zig").expandBraces;
