//! Theming (E04.F08): design tokens, the built-in themes and VS Code
//! theme import.

const std = @import("std");

/// The `tokens.zig` module.
pub const tokens = @import("tokens.zig");
/// The `theme.zig` module.
pub const theme = @import("theme.zig");

/// JSON with comments.
pub const jsonc = @import("jsonc.zig");
/// TextMate scope selectors.
pub const scope_selector = @import("scope_selector.zig");
/// Syntax colouring rules.
pub const syntax_theme = @import("syntax_theme.zig");
/// VS Code theme import.
pub const vscode = @import("vscode.zig");
/// Themes from `.vsix` extensions.
pub const vsix = @import("vsix.zig");

/// See `syntax_theme.SyntaxTheme`.
pub const SyntaxTheme = syntax_theme.SyntaxTheme;
/// See `vscode.ImportResult`.
pub const ImportResult = vscode.ImportResult;
/// See `vscode.importJson`.
pub const importJson = vscode.importJson;
/// See `vsix.importVsix`.
pub const importVsix = vsix.importVsix;
/// See `vsix.listVsixThemes`.
pub const listVsixThemes = vsix.listVsixThemes;

/// See `tokens.Token`.
pub const Token = tokens.Token;
/// See `theme.Theme`.
pub const Theme = theme.Theme;

test {
    std.testing.refAllDecls(@This());
    _ = @import("vscode_test.zig");
}
