//! Position encodings (LSP 3.17 `PositionEncodingKind`) and their
//! negotiation. The offset/position conversion layer of E07.F01.S01.T02
//! lands with E05's snapshots.

const std = @import("std");

/// How `Position.character` counts.
pub const PositionEncoding = enum {
    utf8,
    utf16,
    utf32,

    /// The wire value (`"utf-8"`, ...).
    pub fn wire(e: PositionEncoding) []const u8 {
        return switch (e) {
            .utf8 => "utf-8",
            .utf16 => "utf-16",
            .utf32 => "utf-32",
        };
    }

    /// Parses a wire value.
    pub fn fromWire(s: []const u8) ?PositionEncoding {
        if (std.mem.eql(u8, s, "utf-8")) return .utf8;
        if (std.mem.eql(u8, s, "utf-16")) return .utf16;
        if (std.mem.eql(u8, s, "utf-32")) return .utf32;
        return null;
    }
};

/// What we offer in `general.positionEncodings` (utf-32 only with
/// `lsp.offerUtf32`).
pub const client_position_encodings = [_][]const u8{ "utf-8", "utf-16" };

/// The encoding to use given what we offered and what the server chose
/// (`capabilities.positionEncoding`, or the legacy clangd
/// `offsetEncoding`). A missing choice means utf-16; a choice we did not
/// offer is a protocol violation, logged, and also means utf-16.
pub fn negotiate(client_pref: []const PositionEncoding, server_choice: ?[]const u8) PositionEncoding {
    const s = server_choice orelse return .utf16;
    const e = PositionEncoding.fromWire(s) orelse {
        std.log.scoped(.lsp).warn("server chose unknown position encoding '{s}', using utf-16", .{s});
        return .utf16;
    };
    for (client_pref) |p| if (p == e) return e;
    if (e == .utf16) return .utf16;
    std.log.scoped(.lsp).warn("server chose position encoding '{s}' that was not offered, using utf-16", .{s});
    return .utf16;
}

test "negotiate: matrix" {
    const both = [_]PositionEncoding{ .utf8, .utf16 };
    const all = [_]PositionEncoding{ .utf8, .utf16, .utf32 };
    const t = std.testing;
    try t.expectEqual(PositionEncoding.utf16, negotiate(&both, null));
    try t.expectEqual(PositionEncoding.utf8, negotiate(&both, "utf-8"));
    try t.expectEqual(PositionEncoding.utf16, negotiate(&both, "utf-16"));
    try t.expectEqual(PositionEncoding.utf32, negotiate(&all, "utf-32"));
    // utf-16 is always allowed, even if not listed.
    try t.expectEqual(PositionEncoding.utf16, negotiate(&.{.utf8}, "utf-16"));
}
