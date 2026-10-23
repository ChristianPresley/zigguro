//! LSP language identifiers for zg_syntax languages (the `languageId` of
//! `didOpen` and the registry's `languages`).

const std = @import("std");
const zg_syntax = @import("zg_syntax");

/// The LSP `languageId` of `lang`: its zg_syntax name, except where the
/// LSP's list of known identifiers spells it differently.
pub fn lspId(lang: *const zg_syntax.Language) []const u8 {
    return switch (lang.id) {
        .jsx => "javascriptreact",
        .tsx => "typescriptreact",
        .shell => "shellscript",
        .make => "makefile",
        .plain => "plaintext",
        else => lang.name,
    };
}

test "language: LSP ids" {
    const gpa = std.testing.allocator;
    var reg = try zg_syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    try std.testing.expectEqualStrings("zig", lspId(reg.get(.zig).?));
    try std.testing.expectEqualStrings("cpp", lspId(reg.get(.cpp).?));
    try std.testing.expectEqualStrings("typescriptreact", lspId(reg.get(.tsx).?));
}
