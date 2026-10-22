//! Regex syntax errors: a kind, the offending span and, for errors that
//! involve two places (a duplicate group name, an unclosed group), the other
//! span. `errorMessage` gives the text the find UI shows under the span.

const std = @import("std");
const Span = @import("ast.zig").Span;

/// Every way a pattern can be rejected, at parse or translation time.
pub const ErrorKind = enum {
    unsupported_backreference,
    unsupported_lookaround,
    unsupported_backslash_g,
    unsupported_possessive,
    unsupported_atomic,
    unsupported_octal,
    repetition_count_too_large,
    repetition_count_invalid,
    repetition_missing,
    nest_limit_exceeded,
    class_unclosed,
    class_range_invalid,
    class_empty,
    group_unclosed,
    group_unopened,
    group_name_duplicate,
    group_name_invalid,
    escape_invalid,
    escape_unexpected_eof,
    escape_hex_invalid,
    unicode_property_unknown,
    unicode_not_allowed,
    invalid_utf8,
    flag_unknown,
    flag_duplicate,
    flag_dangling,
    pattern_invalid_utf8,
    pattern_too_long,
    size_limit_exceeded,
};

/// A syntax or translation error.
pub const Error = struct {
    kind: ErrorKind,
    span: Span,
    aux_span: ?Span = null,
};

/// Human text for `e`; the UI shows it with `e.span` underlined.
pub fn errorMessage(e: Error) []const u8 {
    return switch (e.kind) {
        .unsupported_backreference => "backreferences are not supported: they require backtracking",
        .unsupported_lookaround => "look-around is not supported: it requires backtracking",
        .unsupported_backslash_g => "\\G is not supported",
        .unsupported_possessive => "possessive repetition is not supported: it requires backtracking",
        .unsupported_atomic => "atomic groups are not supported: they require backtracking",
        .unsupported_octal => "octal escapes are not supported; use \\x{..} instead",
        .repetition_count_too_large => "repetition count exceeds the limit of 1000",
        .repetition_count_invalid => "invalid repetition count",
        .repetition_missing => "repetition operator has nothing to repeat",
        .nest_limit_exceeded => "pattern nests too deeply",
        .class_unclosed => "unclosed character class",
        .class_range_invalid => "invalid character class range",
        .class_empty => "character class set operation has an empty operand",
        .group_unclosed => "unclosed group",
        .group_unopened => "unopened group",
        .group_name_duplicate => "duplicate capture group name",
        .group_name_invalid => "invalid capture group name",
        .escape_invalid => "unrecognized escape sequence",
        .escape_unexpected_eof => "pattern ends with an incomplete escape",
        .escape_hex_invalid => "invalid hexadecimal escape",
        .unicode_property_unknown => "unknown Unicode property or value",
        .unicode_not_allowed => "Unicode classes are not allowed when Unicode mode is off",
        .invalid_utf8 => "pattern can match invalid UTF-8 but Unicode mode requires valid UTF-8",
        .flag_unknown => "unknown flag",
        .flag_duplicate => "duplicate flag",
        .flag_dangling => "flag negation has no flag",
        .pattern_invalid_utf8 => "pattern is not valid UTF-8",
        .pattern_too_long => "pattern is longer than 1 MiB",
        .size_limit_exceeded => "compiled regex exceeds the size limit",
    };
}

test "errorMessage: every kind has text" {
    inline for (std.meta.fields(ErrorKind)) |f| {
        const msg = errorMessage(.{ .kind = @enumFromInt(f.value), .span = .{ .start = 0, .end = 0 } });
        try std.testing.expect(msg.len > 0);
    }
}
