//! Atoms interned in one round trip.

const std = @import("std");

/// The atoms for `names`, looked up by name at comptime.
pub fn AtomTable(comptime names: []const []const u8) type {
    return struct {
        const Self = @This();
        /// The atom names, in order.
        pub const atom_names = names;
        ids: [names.len]u32 = @splat(0),

        /// The atom for `atom_name`, which must be in `names`.
        pub fn get(t: *const Self, comptime atom_name: []const u8) u32 {
            const i = comptime blk: {
                for (names, 0..) |n, k| if (std.mem.eql(u8, n, atom_name)) break :blk k;
                @compileError("atom not in table: " ++ atom_name);
            };
            return t.ids[i];
        }

        /// The name of `atom` if it is in the table.
        pub fn name(t: *const Self, atom: u32) ?[]const u8 {
            for (t.ids, 0..) |id, k| if (id == atom and atom != 0) return names[k];
            return null;
        }
    };
}

test "atom table lookup" {
    var t: AtomTable(&.{ "WM_PROTOCOLS", "UTF8_STRING" }) = .{};
    t.ids = .{ 300, 301 };
    try std.testing.expectEqual(301, t.get("UTF8_STRING"));
    try std.testing.expectEqualStrings("WM_PROTOCOLS", t.name(300).?);
    try std.testing.expectEqual(null, t.name(5));
}
