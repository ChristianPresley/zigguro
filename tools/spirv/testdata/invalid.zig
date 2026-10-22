//! Hand-crafted invalid modules for the validator tests (E02.F05.S01.T04),
//! built with the builder's raw mode. Each case names the message
//! substring the validator must report.

const std = @import("std");
const b = @import("../builder.zig");

const Case = struct {
    name: []const u8,
    expect: []const u8,
    build: *const fn (std.mem.Allocator) anyerror![]u32,
};

/// A fragment shader whose body `body` fills (after the first label).
fn withBody(gpa: std.mem.Allocator, comptime body: fn (*b.Module, *b.Function) anyerror!void) ![]u32 {
    var m: b.Module = .init(gpa, .{});
    defer m.deinit();
    const f = try m.function(try m.typeVoid(), &.{});
    try f.label(m.newId());
    try body(&m, f);
    try m.entryPoint(.Fragment, f, "main", &.{});
    try m.executionMode(f, .OriginUpperLeft);
    return m.finish();
}

fn minimal(gpa: std.mem.Allocator) ![]u32 {
    return b.minimalFrag(gpa);
}

pub const cases = [_]Case{
    .{ .name = "undefined id", .expect = "undefined id %", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    const ghost = m.newId();
                    const c = try m.constant(try m.typeFloat(32), 1.0);
                    try f_.op(.OpStore, &.{ ghost.word(), c.word() });
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "duplicate definition", .expect = "defined twice", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    const x = m.newId();
                    try m.raw(.global, .OpTypeInt, &.{ x.word(), 32, 0 });
                    try m.raw(.global, .OpTypeInt, &.{ x.word(), 16, 0 });
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "bad section order", .expect = "out of section order", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    try m.raw(.global, .OpCapability, &.{@intFromEnum(b.Capability.Float64)});
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "missing merge", .expect = "missing OpSelectionMerge", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    const t = try m.constant(try m.typeBool(), true);
                    const l1 = m.newId();
                    const l2 = m.newId();
                    try f_.op(.OpBranchConditional, &.{ t.word(), l1.word(), l2.word() });
                    try f_.label(l1);
                    try f_.op(.OpReturn, &.{});
                    try f_.label(l2);
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "missing terminator", .expect = "missing block terminator", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(_: *b.Module, _: *b.Function) !void {}
            }.body);
        }
    }.f },
    .{ .name = "missing Offset", .expect = "has no Offset decoration", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    const f32_t = try m.typeFloat(32);
                    const s = try m.typeStruct(&.{ f32_t, f32_t });
                    try m.decorate(s, .Block);
                    try m.memberDecorate(s, 0, .{ .Offset = 0 });
                    const v = try m.variable(try m.typePointer(.PushConstant, s), .PushConstant);
                    _ = v;
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "missing ArrayStride", .expect = "has no ArrayStride decoration", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    const f32_t = try m.typeFloat(32);
                    const arr = try m.typeRuntimeArray(f32_t);
                    const s = try m.typeStruct(&.{arr});
                    try m.decorate(s, .Block);
                    try m.memberDecorate(s, 0, .{ .Offset = 0 });
                    const v = try m.variable(try m.typePointer(.StorageBuffer, s), .StorageBuffer);
                    try m.decorate(v, .{ .DescriptorSet = 0 });
                    try m.decorate(v, .{ .Binding = 0 });
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{
        .name = "truncated instruction",
        .expect = "truncated instruction",
        .build = struct {
            fn f(gpa: std.mem.Allocator) ![]u32 {
                const words = try minimal(gpa);
                // The last instruction (OpFunctionEnd) claims three words.
                words[words.len - 1] = 3 << 16 | (words[words.len - 1] & 0xffff);
                return words;
            }
        }.f,
    },
    .{
        .name = "use before definition",
        .expect = "used before its definition",
        .build = struct {
            fn f(gpa: std.mem.Allocator) ![]u32 {
                return withBody(gpa, struct {
                    fn body(m: *b.Module, f_: *b.Function) !void {
                        const f32_t = try m.typeFloat(32);
                        const later = m.newId();
                        const c = try m.constant(f32_t, 2.0);
                        _ = try f_.result(.OpFNegate, f32_t, &.{later.word()});
                        // %later is defined by the next instruction.
                        try b.encode(m.gpa, &f_.body, .OpFNegate, &.{ f32_t.word(), later.word(), c.word() });
                        try f_.op(.OpReturn, &.{});
                    }
                }.body);
            }
        }.f,
    },
    .{ .name = "bad magic", .expect = "bad magic", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            const words = try minimal(gpa);
            words[0] = 0x0203_2307;
            return words;
        }
    }.f },
    .{ .name = "version above the ceiling", .expect = "above the vulkan_1_2 ceiling", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            const words = try minimal(gpa);
            words[1] = 0x0001_0600;
            return words;
        }
    }.f },
    .{ .name = "interface storage class", .expect = "allows only Input/Output", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            var m: b.Module = .init(gpa, .{});
            defer m.deinit();
            const p = try m.variable(try m.typePointer(.Private, try m.typeFloat(32)), .Private);
            const fun = try m.function(try m.typeVoid(), &.{});
            try fun.label(m.newId());
            try fun.op(.OpReturn, &.{});
            try m.entryPoint(.Fragment, fun, "main", &.{p});
            try m.executionMode(fun, .OriginUpperLeft);
            return m.finish();
        }
    }.f },
    .{ .name = "variable not first", .expect = "function variable not at the start", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    const f32_t = try m.typeFloat(32);
                    const ptr = try m.typePointer(.Function, f32_t);
                    try f_.op(.OpNop, &.{});
                    _ = try f_.result(.OpVariable, ptr, &.{@intFromEnum(b.StorageClass.Function)});
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "missing label", .expect = "missing OpLabel", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(_: *b.Module, f_: *b.Function) !void {
                    try f_.op(.OpReturn, &.{});
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
    .{ .name = "short instruction", .expect = "the grammar needs at least", .build = struct {
        fn f(gpa: std.mem.Allocator) ![]u32 {
            return withBody(gpa, struct {
                fn body(m: *b.Module, f_: *b.Function) !void {
                    try m.raw(.global, .OpTypeInt, &.{m.newId().word()});
                    try f_.op(.OpReturn, &.{});
                }
            }.body);
        }
    }.f },
};
