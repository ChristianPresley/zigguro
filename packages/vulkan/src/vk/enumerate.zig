//! The two-call enumerate idiom: ask for the count, allocate, fill, and
//! retry while the implementation reports `VK_INCOMPLETE`.

const std = @import("std");
const vk = @import("vk.zig");

/// Calls `f(args..., &count, null)`, allocates `count` items of `T` and
/// calls `f(args..., &count, items)`. Works for commands returning
/// `Result` (retrying on `incomplete`) and for those returning `void`.
/// Items of a struct type with defaults (`s_type`) are default-initialised
/// before the second call. The caller frees the result with `gpa`.
pub fn enumerateAlloc(comptime T: type, gpa: std.mem.Allocator, f: anytype, args: anytype) (vk.Error || error{OutOfMemory})![]T {
    const returns_result = @typeInfo(@typeInfo(@TypeOf(f)).pointer.child).@"fn".return_type.? == vk.Result;
    while (true) {
        var n: u32 = 0;
        if (returns_result) {
            _ = try vk.check(@call(.auto, f, args ++ .{ &n, null }));
        } else {
            @call(.auto, f, args ++ .{ &n, null });
        }
        const items = try gpa.alloc(T, n);
        errdefer gpa.free(items);
        if (@typeInfo(T) == .@"struct" and comptime hasDefaults(T)) @memset(items, .{});
        if (n == 0) return items;
        if (returns_result) {
            const r = try vk.check(@call(.auto, f, args ++ .{ &n, items.ptr }));
            if (r == .incomplete) {
                gpa.free(items);
                continue;
            }
        } else {
            @call(.auto, f, args ++ .{ &n, items.ptr });
        }
        if (n < items.len) return gpa.realloc(items, n);
        return items;
    }
}

fn hasDefaults(comptime T: type) bool {
    for (@typeInfo(T).@"struct".fields) |fld| if (fld.default_value_ptr == null) return false;
    return true;
}
