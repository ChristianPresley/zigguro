//! C sizes and alignments of Vulkan types on 64-bit targets (x86_64 and
//! aarch64, SysV and Win64 agree for every Vulkan type). The emitter turns
//! them into compile-time checks of the generated extern structs.

const std = @import("std");
const registry = @import("registry.zig");
const Registry = registry.Registry;

/// Size and alignment in bytes.
pub const Layout = struct {
    size: u64,
    @"align": u64,
};

pub const Error = error{ OutOfMemory, UnknownLayout };

const ptr: Layout = .{ .size = 8, .@"align" = 8 };

/// The layout of a C primitive or platform type, or null.
pub fn primitive(name: []const u8) ?Layout {
    const table = [_]struct { []const u8, u64 }{
        .{ "char", 1 },     .{ "uint8_t", 1 },  .{ "int8_t", 1 },
        .{ "uint16_t", 2 }, .{ "int16_t", 2 },  .{ "uint32_t", 4 },
        .{ "int32_t", 4 },  .{ "int", 4 },      .{ "float", 4 },
        .{ "DWORD", 4 },    .{ "uint64_t", 8 }, .{ "int64_t", 8 },
        .{ "double", 8 },   .{ "size_t", 8 },   .{ "HINSTANCE", 8 },
        .{ "HWND", 8 },     .{ "HANDLE", 8 },   .{ "HMONITOR", 8 },
        .{ "LPCWSTR", 8 },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return .{ .size = e[1], .@"align" = e[1] };
    return null;
}

/// Memoised layout computation over a registry.
pub const Calc = struct {
    reg: *const Registry,
    a: std.mem.Allocator,
    cache: std.StringHashMapUnmanaged(Layout) = .empty,
    /// API constant values for array dimensions.
    constants: *const std.StringHashMapUnmanaged(u64),
    /// The type whose layout was unknown.
    culprit: []const u8 = "",

    pub fn of(self: *Calc, name: []const u8) Error!Layout {
        if (self.cache.get(name)) |l| return l;
        const l = try self.compute(name);
        try self.cache.put(self.a, name, l);
        return l;
    }

    fn compute(self: *Calc, name: []const u8) Error!Layout {
        if (primitive(name)) |l| return l;
        const t = self.reg.types.get(name) orelse return self.unknown(name);
        if (t.alias) |al| return self.of(al);
        return switch (t.category) {
            .handle, .funcpointer => ptr,
            .@"enum" => .{ .size = 4, .@"align" = 4 },
            .bitmask, .basetype => if (t.base) |b| (if (b.ptr_depth > 0) ptr else self.of(b.base)) else self.unknown(name),
            .@"struct", .@"union" => self.aggregate(t),
            else => self.unknown(name),
        };
    }

    fn unknown(self: *Calc, name: []const u8) Error {
        self.culprit = name;
        return error.UnknownLayout;
    }

    /// The layout of one member (pointers, arrays).
    pub fn member(self: *Calc, d: registry.Decl) Error!Layout {
        if (d.ty.ptr_depth > 0) return ptr;
        var l = try self.of(d.ty.base);
        for (d.ty.dims) |dim| {
            const n: u64 = switch (dim) {
                .lit => |x| x,
                .constant => |c| self.constants.get(c) orelse return self.unknown(c),
            };
            l.size *= n;
        }
        return l;
    }

    fn aggregate(self: *Calc, t: registry.Type) Error!Layout {
        var size: u64 = 0;
        var al: u64 = 1;
        var bits_left: u32 = 0; // free bits in the current bit-field unit
        for (t.members) |m| {
            if (m.ty.bitfield) |w| {
                if (bits_left < w) {
                    size = std.mem.alignForward(u64, size, 4) + 4;
                    al = @max(al, 4);
                    bits_left = 32;
                }
                bits_left -= w;
                continue;
            }
            bits_left = 0;
            const l = try self.member(m);
            al = @max(al, l.@"align");
            if (t.category == .@"union") {
                size = @max(size, l.size);
            } else {
                size = std.mem.alignForward(u64, size, l.@"align") + l.size;
            }
        }
        return .{ .size = std.mem.alignForward(u64, size, al), .@"align" = al };
    }
};

test "layout: known structs" {
    var reg = try Registry.parse(std.testing.allocator, @embedFile("data/vk.xml"));
    defer reg.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var consts: std.StringHashMapUnmanaged(u64) = .empty;
    const g = reg.enums.get("API Constants").?;
    for (g.values.items) |v| if (v.value == .int) try consts.put(arena.allocator(), v.name, @intCast(v.value.int));
    var c: Calc = .{ .reg = &reg, .a = arena.allocator(), .constants = &consts };
    // Sizes from the C headers on x86_64 Linux.
    const expect = [_]struct { []const u8, u64, u64 }{
        .{ "VkImageCreateInfo", 88, 8 },
        .{ "VkApplicationInfo", 48, 8 },
        .{ "VkInstanceCreateInfo", 64, 8 },
        .{ "VkExtent3D", 12, 4 },
        .{ "VkPhysicalDeviceProperties", 824, 8 },
        .{ "VkPhysicalDeviceLimits", 504, 8 },
        .{ "VkPhysicalDeviceMemoryProperties", 520, 8 },
        .{ "VkClearValue", 16, 4 },
        .{ "VkAccelerationStructureInstanceKHR", 64, 8 },
        .{ "VkDebugUtilsMessengerCreateInfoEXT", 48, 8 },
        .{ "VkPhysicalDeviceFeatures", 220, 4 },
        .{ "VkBufferImageCopy", 56, 8 },
    };
    for (expect) |e| {
        const l = try c.of(e[0]);
        std.testing.expectEqual(e[1], l.size) catch |err| {
            std.debug.print("{s}\n", .{e[0]});
            return err;
        };
        try std.testing.expectEqual(e[2], l.@"align");
    }
}
