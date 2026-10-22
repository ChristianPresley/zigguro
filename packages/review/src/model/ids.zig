//! Identifiers of the review model (E12.F01.S01.T01).

const std = @import("std");

/// A changeset, unique and increasing within one workspace store; printed
/// as `#<n>`. 0 is never assigned.
pub const ChangesetId = enum(u64) {
    _,

    pub fn format(id: ChangesetId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{d}", .{@intFromEnum(id)});
    }
};

/// E08 drafts spell it this way.
pub const ChangeSetId = ChangesetId;

/// An open batch of a `Queue` (not persisted).
pub const BatchId = enum(u64) { _ };

/// One hunk of one file of one changeset.
pub const HunkRef = struct { cs: ChangesetId, file: u32, hunk: u32 };

/// BLAKE3 of a blob's bytes.
pub const BlobHash = [32]u8;

/// The BLAKE3 hash of `bytes`.
pub fn blobHash(bytes: []const u8) BlobHash {
    var h: BlobHash = undefined;
    std.crypto.hash.Blake3.hash(bytes, &h, .{});
    return h;
}

test "ids: changeset id prints as #n" {
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{@as(ChangesetId, @enumFromInt(42))});
    try std.testing.expectEqualStrings("#42", s);
}

test "ids: blob hash is BLAKE3" {
    // BLAKE3("") from the reference test vectors.
    const want = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262";
    var got: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&got, "{x}", .{&blobHash("")});
    try std.testing.expectEqualStrings(want, &got);
}
