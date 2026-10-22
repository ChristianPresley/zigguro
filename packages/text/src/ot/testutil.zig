//! Test-only builders for font files.

const std = @import("std");

/// Assembles a TTC v1 holding `faces` (each a plain sfnt). Table data is
/// copied per face and the directory offsets rewritten; tables are not
/// shared between faces.
pub fn buildTtc(gpa: std.mem.Allocator, faces: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const header_len = 12 + 4 * faces.len;
    try out.appendNTimes(gpa, 0, header_len);
    @memcpy(out.items[0..4], "ttcf");
    std.mem.writeInt(u16, out.items[4..6], 1, .big);
    std.mem.writeInt(u32, out.items[8..12], @intCast(faces.len), .big);
    for (faces, 0..) |face, fi| {
        try pad4(gpa, &out);
        const dir_off = out.items.len;
        std.mem.writeInt(u32, out.items[12 + fi * 4 ..][0..4], @intCast(dir_off), .big);
        const n = std.mem.readInt(u16, face[4..6], .big);
        const dir_len = 12 + @as(usize, n) * 16;
        try out.appendSlice(gpa, face[0..dir_len]);
        for (0..n) |i| {
            const rec = 12 + i * 16;
            const off = std.mem.readInt(u32, face[rec + 8 ..][0..4], .big);
            const len = std.mem.readInt(u32, face[rec + 12 ..][0..4], .big);
            try pad4(gpa, &out);
            const new_off = out.items.len;
            try out.appendSlice(gpa, face[off..][0..len]);
            std.mem.writeInt(u32, out.items[dir_off + rec + 8 ..][0..4], @intCast(new_off), .big);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn pad4(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    while (out.items.len % 4 != 0) try out.append(gpa, 0);
}
