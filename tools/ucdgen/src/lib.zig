//! The ucdgen library: parsing, the uncompressed reference tables, blob
//! emission and input verification. Exported as the `ucdgen_ref` module so
//! zg_text's tests can compare the generated tables against it.

const std = @import("std");

pub const parse = @import("parse.zig");
pub const tables = @import("tables.zig");
pub const emit = @import("emit.zig");

pub const Ucd = tables.Ucd;
pub const Inputs = tables.Inputs;
pub const Diag = tables.Diag;
pub const files = tables.files;
pub const code_points = tables.code_points;
pub const build = tables.build;

/// Whether `path` ends with the `/`-separated relative path `rel`, treating
/// `\\` in `path` as `/` so Windows build paths match.
pub fn pathEndsWith(path: []const u8, rel: []const u8) bool {
    if (path.len < rel.len) return false;
    for (path[path.len - rel.len ..], rel) |a, b| {
        const n = if (a == '\\') '/' else a;
        if (n != b) return false;
    }
    return true;
}

test "pathEndsWith accepts either separator" {
    try std.testing.expect(pathEndsWith("a/ucd/extracted/X.txt", "extracted/X.txt"));
    try std.testing.expect(pathEndsWith("D:\\a\\ucd\\extracted\\X.txt", "extracted/X.txt"));
    try std.testing.expect(!pathEndsWith("a/ucd/X.txt", "extracted/X.txt"));
}

/// One `manifest.zon` entry.
pub const ManifestEntry = struct { file: []const u8, sha256: []const u8 };

/// Why `verifyInputs` failed, for the error message.
pub const VerifyDiag = struct { file: []const u8 = "", want: [64]u8 = @splat('0'), got: [64]u8 = @splat('0') };

/// Checks every input against its SHA-256 in `manifest`.
pub fn verifyInputs(manifest: []const ManifestEntry, inputs: *const Inputs, diag: *VerifyDiag) error{ NotInManifest, ChecksumMismatch }!void {
    for (files, inputs) |rel, data| {
        const want = for (manifest) |m| {
            if (std.mem.eql(u8, m.file, rel)) break m.sha256;
        } else {
            diag.file = rel;
            return error.NotInManifest;
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &got, want)) {
            diag.file = rel;
            diag.got = got;
            if (want.len == 64) @memcpy(&diag.want, want[0..64]);
            return error.ChecksumMismatch;
        }
    }
}

/// Runs the whole pipeline in memory: alias check, tables, blob. Returns
/// the blob bytes (owned by `arena`).
pub fn generate(arena: std.mem.Allocator, gpa: std.mem.Allocator, inputs: *const Inputs, diag: *Diag) ![]const u8 {
    try tables.checkAliases(inputs[tables.fileIndex("PropertyValueAliases.txt")], diag);
    var ucd = try tables.build(gpa, inputs, diag);
    defer ucd.deinit();
    const blob = try emit.buildBlob(arena, &ucd);
    return blob.bytes.items;
}
