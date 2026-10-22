//! The shader DSL (E02.F05.S01.T02): typed values over the module
//! builder, so shader programs read like Zig.
//!
//! A program is a function `fn build(s: *Shader) !void` that runs at build
//! time (tools/shaderc). `Val(T)` is an SSA value of Zig type `T` (f32,
//! u32, i32, bool or a `@Vector` of them); arithmetic emits the matching
//! SPIR-V op and the math built-ins go through GLSL.std.450.
//!
//! Structured control flow is imperative: `beginIf` / `orElse` / `end`
//! and `beginSwitch` / `case` / `end` emit the merge instruction, the
//! branches and an `OpPhi` for the result. Buffer layouts come from
//! `extern struct`s via `@offsetOf`/`@sizeOf`, so the CPU-side struct is
//! the single source of truth.

const std = @import("std");
const spec = @import("spec.zig");
const builder = @import("builder.zig");

const Id = builder.Id;
const Module = builder.Module;
const Function = builder.Function;
const Opcode = spec.Opcode;

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);
pub const UVec2 = @Vector(2, u32);
pub const UVec4 = @Vector(4, u32);
pub const BVec2 = @Vector(2, bool);
pub const BVec4 = @Vector(4, bool);

pub const Stage = enum { vertex, fragment };

/// One shader program: `build` emits the body of `main` for `stage`.
/// `name` (e.g. `prim_frag`) names the generated `.spv` and the
/// declaration in the `shaders` module.
pub const Program = struct {
    name: []const u8,
    stage: Stage,
    build: *const fn (*Shader) anyerror!void,
};

pub const Error = builder.Error;

const Scalar = enum { f32, u32, i32, bool };

fn scalarOf(comptime T: type) Scalar {
    return switch (T) {
        f32 => .f32,
        u32 => .u32,
        i32 => .i32,
        bool => .bool,
        else => switch (@typeInfo(T)) {
            .vector => |v| scalarOf(v.child),
            else => @compileError("not a DSL value type: " ++ @typeName(T)),
        },
    };
}

fn lanes(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .vector => |v| v.len,
        else => 1,
    };
}

fn Elem(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .vector => |v| v.child,
        else => T,
    };
}

/// `T` with its scalar replaced by `S` (same lane count).
fn WithScalar(comptime T: type, comptime S: type) type {
    return if (lanes(T) == 1) S else @Vector(lanes(T), S);
}

/// An SSA value of Zig type `T`.
pub fn Val(comptime T: type) type {
    return struct {
        s: *Shader,
        id: Id,

        const Self = @This();
        pub const Type = T;
        const sc = scalarOf(T);

        fn bin(a: Self, comptime fop: Opcode, comptime uop: Opcode, comptime iop: Opcode, b: Self) Error!Self {
            const op = comptime switch (sc) {
                .f32 => fop,
                .u32 => uop,
                .i32 => iop,
                .bool => @compileError("arithmetic on bool"),
            };
            return a.s.op(T, op, &.{ a.id.word(), b.id.word() });
        }

        pub fn add(a: Self, b: Self) Error!Self {
            return a.bin(.OpFAdd, .OpIAdd, .OpIAdd, b);
        }
        pub fn sub(a: Self, b: Self) Error!Self {
            return a.bin(.OpFSub, .OpISub, .OpISub, b);
        }
        pub fn mul(a: Self, b: Self) Error!Self {
            return a.bin(.OpFMul, .OpIMul, .OpIMul, b);
        }
        pub fn div(a: Self, b: Self) Error!Self {
            return a.bin(.OpFDiv, .OpUDiv, .OpSDiv, b);
        }
        pub fn neg(a: Self) Error!Self {
            return a.s.op(T, if (sc == .f32) .OpFNegate else .OpSNegate, &.{a.id.word()});
        }
        /// Vector times scalar.
        pub fn scale(a: Self, k: Val(Elem(T))) Error!Self {
            if (comptime lanes(T) == 1) return a.mul(k);
            return a.s.op(T, .OpVectorTimesScalar, &.{ a.id.word(), k.id.word() });
        }
        pub fn dot(a: Self, b: Self) Error!Val(Elem(T)) {
            return a.s.op(Elem(T), .OpDot, &.{ a.id.word(), b.id.word() });
        }

        fn ext(a: Self, comptime R: type, comptime f: spec.GlslStd450, rest: []const Id) Error!Val(R) {
            var args: [4]Id = undefined;
            args[0] = a.id;
            @memcpy(args[1..][0..rest.len], rest);
            return .{ .s = a.s, .id = try a.s.f.glsl(try a.s.typeOf(R), f, args[0 .. rest.len + 1]) };
        }

        pub fn length(a: Self) Error!Val(Elem(T)) {
            return a.ext(Elem(T), .Length, &.{});
        }
        pub fn abs(a: Self) Error!Self {
            return a.ext(T, if (sc == .f32) .FAbs else .SAbs, &.{});
        }
        pub fn sqrt(a: Self) Error!Self {
            return a.ext(T, .Sqrt, &.{});
        }
        pub fn exp(a: Self) Error!Self {
            return a.ext(T, .Exp, &.{});
        }
        pub fn log(a: Self) Error!Self {
            return a.ext(T, .Log, &.{});
        }
        pub fn floor(a: Self) Error!Self {
            return a.ext(T, .Floor, &.{});
        }
        pub fn ceil(a: Self) Error!Self {
            return a.ext(T, .Ceil, &.{});
        }
        pub fn fract(a: Self) Error!Self {
            return a.ext(T, .Fract, &.{});
        }
        pub fn sign(a: Self) Error!Self {
            return a.ext(T, .FSign, &.{});
        }
        pub fn pow(a: Self, b: Self) Error!Self {
            return a.ext(T, .Pow, &.{b.id});
        }
        pub fn min(a: Self, b: Self) Error!Self {
            return a.ext(T, switch (sc) {
                .f32 => .FMin,
                .u32 => .UMin,
                .i32 => .SMin,
                .bool => unreachable,
            }, &.{b.id});
        }
        pub fn max(a: Self, b: Self) Error!Self {
            return a.ext(T, switch (sc) {
                .f32 => .FMax,
                .u32 => .UMax,
                .i32 => .SMax,
                .bool => unreachable,
            }, &.{b.id});
        }
        pub fn clamp(a: Self, lo: Self, hi: Self) Error!Self {
            return a.ext(T, switch (sc) {
                .f32 => .FClamp,
                .u32 => .UClamp,
                .i32 => .SClamp,
                .bool => unreachable,
            }, &.{ lo.id, hi.id });
        }
        /// `a * (1 - t) + b * t`.
        pub fn mix(a: Self, b: Self, t: Self) Error!Self {
            return a.ext(T, .FMix, &.{ b.id, t.id });
        }
        /// `smoothstep(e0, e1, x)` with `a` as `x`.
        pub fn smoothstep(a: Self, e0: Self, e1: Self) Error!Self {
            const r = try a.s.f.glsl(try a.s.typeOf(T), .SmoothStep, &.{ e0.id, e1.id, a.id });
            return .{ .s = a.s, .id = r };
        }

        fn cmp(a: Self, comptime fop: Opcode, comptime uop: Opcode, comptime iop: Opcode, b: Self) Error!Val(WithScalar(T, bool)) {
            const op = comptime switch (sc) {
                .f32 => fop,
                .u32 => uop,
                .i32 => iop,
                .bool => @compileError("ordered compare on bool"),
            };
            return a.s.op(WithScalar(T, bool), op, &.{ a.id.word(), b.id.word() });
        }
        pub fn lt(a: Self, b: Self) Error!Val(WithScalar(T, bool)) {
            return a.cmp(.OpFOrdLessThan, .OpULessThan, .OpSLessThan, b);
        }
        pub fn le(a: Self, b: Self) Error!Val(WithScalar(T, bool)) {
            return a.cmp(.OpFOrdLessThanEqual, .OpULessThanEqual, .OpSLessThanEqual, b);
        }
        pub fn gt(a: Self, b: Self) Error!Val(WithScalar(T, bool)) {
            return a.cmp(.OpFOrdGreaterThan, .OpUGreaterThan, .OpSGreaterThan, b);
        }
        pub fn ge(a: Self, b: Self) Error!Val(WithScalar(T, bool)) {
            return a.cmp(.OpFOrdGreaterThanEqual, .OpUGreaterThanEqual, .OpSGreaterThanEqual, b);
        }
        pub fn eq(a: Self, b: Self) Error!Val(WithScalar(T, bool)) {
            if (sc == .bool) return a.s.op(T, .OpLogicalEqual, &.{ a.id.word(), b.id.word() });
            return a.cmp(.OpFOrdEqual, .OpIEqual, .OpIEqual, b);
        }
        pub fn ne(a: Self, b: Self) Error!Val(WithScalar(T, bool)) {
            if (sc == .bool) return a.s.op(T, .OpLogicalNotEqual, &.{ a.id.word(), b.id.word() });
            return a.cmp(.OpFUnordNotEqual, .OpINotEqual, .OpINotEqual, b);
        }

        pub fn @"and"(a: Self, b: Self) Error!Self {
            return a.s.op(T, if (sc == .bool) .OpLogicalAnd else .OpBitwiseAnd, &.{ a.id.word(), b.id.word() });
        }
        pub fn @"or"(a: Self, b: Self) Error!Self {
            return a.s.op(T, if (sc == .bool) .OpLogicalOr else .OpBitwiseOr, &.{ a.id.word(), b.id.word() });
        }
        pub fn not(a: Self) Error!Self {
            return a.s.op(T, if (sc == .bool) .OpLogicalNot else .OpNot, &.{a.id.word()});
        }
        pub fn shr(a: Self, b: Self) Error!Self {
            return a.s.op(T, if (sc == .i32) .OpShiftRightArithmetic else .OpShiftRightLogical, &.{ a.id.word(), b.id.word() });
        }
        pub fn shl(a: Self, b: Self) Error!Self {
            return a.s.op(T, .OpShiftLeftLogical, &.{ a.id.word(), b.id.word() });
        }

        /// `cond ? a : b`, per component (`cond` has `T`'s lane count).
        pub fn select(cond: Val(WithScalar(T, bool)), a: Self, b: Self) Error!Self {
            return a.s.op(T, .OpSelect, &.{ cond.id.word(), a.id.word(), b.id.word() });
        }

        /// Numeric conversion to the same lane count of scalar `S`.
        pub fn to(a: Self, comptime S: type) Error!Val(WithScalar(T, S)) {
            const R = WithScalar(T, S);
            const op: Opcode = comptime switch (sc) {
                .f32 => switch (scalarOf(S)) {
                    .u32 => .OpConvertFToU,
                    .i32 => .OpConvertFToS,
                    else => @compileError("bad conversion"),
                },
                .u32 => switch (scalarOf(S)) {
                    .f32 => .OpConvertUToF,
                    .i32 => .OpBitcast,
                    else => @compileError("bad conversion"),
                },
                .i32 => switch (scalarOf(S)) {
                    .f32 => .OpConvertSToF,
                    .u32 => .OpBitcast,
                    else => @compileError("bad conversion"),
                },
                .bool => @compileError("bad conversion"),
            };
            return a.s.op(R, op, &.{a.id.word()});
        }

        /// Same-size reinterpretation (`f32` <-> `u32`).
        pub fn bitcast(a: Self, comptime S: type) Error!Val(WithScalar(T, S)) {
            return a.s.op(WithScalar(T, S), .OpBitcast, &.{a.id.word()});
        }

        /// Component `i`.
        pub fn at(a: Self, comptime i: u32) Error!Val(Elem(T)) {
            return a.s.op(Elem(T), .OpCompositeExtract, &.{ a.id.word(), i });
        }
        pub fn x(a: Self) Error!Val(Elem(T)) {
            return a.at(0);
        }
        pub fn y(a: Self) Error!Val(Elem(T)) {
            return a.at(1);
        }
        pub fn z(a: Self) Error!Val(Elem(T)) {
            return a.at(2);
        }
        pub fn w(a: Self) Error!Val(Elem(T)) {
            return a.at(3);
        }

        /// A swizzle such as "xy", "zw" or "bgra".
        pub fn swizzle(a: Self, comptime pat: []const u8) Error!Val(if (pat.len == 1) Elem(T) else @Vector(pat.len, Elem(T))) {
            if (pat.len == 1) return a.at(comptime lane(pat[0]));
            var words: [6]u32 = undefined;
            words[0] = a.id.word();
            words[1] = a.id.word();
            inline for (pat, 0..) |ch, i| words[2 + i] = comptime lane(ch);
            return a.s.op(@Vector(pat.len, Elem(T)), .OpVectorShuffle, words[0 .. 2 + pat.len]);
        }

        fn lane(comptime ch: u8) u32 {
            return switch (ch) {
                'x', 'r' => 0,
                'y', 'g' => 1,
                'z', 'b' => 2,
                'w', 'a' => 3,
                else => @compileError("bad swizzle"),
            };
        }
    };
}

/// A pointer to a `T` (a local, an output or a buffer element field).
pub fn Ptr(comptime T: type) type {
    return struct {
        s: *Shader,
        id: Id,

        pub fn load(p: @This()) Error!Val(T) {
            return p.s.op(T, .OpLoad, &.{p.id.word()});
        }
        pub fn store(p: @This(), v: Val(T)) Error!void {
            try p.s.f.op(.OpStore, &.{ p.id.word(), v.id.word() });
        }
    };
}

/// A field-addressable view of a buffer element or push-constant block of
/// extern struct type `S`.
pub fn Fields(comptime S: type) type {
    return struct {
        s: *Shader,
        /// The access-chain base and the indices leading to the struct.
        base: Id,
        sc: spec.StorageClass,
        prefix: [2]Id,
        prefix_len: u8,

        /// Loads field `name`.
        pub fn get(v: @This(), comptime name: []const u8) Error!Val(FieldType(S, name)) {
            const F = FieldType(S, name);
            const s = v.s;
            const idx = std.meta.fieldIndex(S, name).?;
            const ptr_t = try s.m.typePointer(v.sc, try s.typeOf(F));
            var words: [5]u32 = undefined;
            words[0] = v.base.word();
            for (v.prefix[0..v.prefix_len], 1..) |p, i| words[i] = p.word();
            words[1 + v.prefix_len] = (try s.m.constant(try s.m.typeInt(32, false), idx)).word();
            const p = try s.f.result(.OpAccessChain, ptr_t, words[0 .. 2 + v.prefix_len]);
            return s.op(F, .OpLoad, &.{p.word()});
        }
    };
}

fn FieldType(comptime S: type, comptime name: []const u8) type {
    const F = @FieldType(S, name);
    return switch (@typeInfo(F)) {
        // Arrays of 2..4 numbers are vectors in the shader.
        .array => |a| @Vector(a.len, a.child),
        else => F,
    };
}

/// A read-only `Elem items[]` storage buffer.
pub fn StorageArray(comptime E: type) type {
    return struct {
        s: *Shader,
        var_id: Id,

        /// Element `index` (a field view).
        pub fn at(a: @This(), index: Val(u32)) Error!Fields(E) {
            const zero = try a.s.m.constant(try a.s.m.typeInt(32, false), 0);
            return .{ .s = a.s, .base = a.var_id, .sc = .StorageBuffer, .prefix = .{ zero, index.id }, .prefix_len = 2 };
        }
    };
}

/// `sampler2D textures[]`, indexed non-uniformly.
pub const SampledImageArray = struct {
    s: *Shader,
    var_id: Id,
    sampled_image_t: Id,

    /// `textures[nonuniformEXT(index)]`.
    pub fn at(a: SampledImageArray, index: Val(u32)) Error!SampledImage {
        const s = a.s;
        try s.nonUniform(index.id);
        const ptr_t = try s.m.typePointer(.UniformConstant, a.sampled_image_t);
        const p = try s.f.result(.OpAccessChain, ptr_t, &.{ a.var_id.word(), index.id.word() });
        try s.m.decorate(p, .NonUniform);
        const img = try s.f.result(.OpLoad, a.sampled_image_t, &.{p.word()});
        try s.m.decorate(img, .NonUniform);
        return .{ .s = s, .id = img };
    }

    /// `textureLod(textures[nonuniformEXT(index)], uv, 0)`.
    pub fn sample(a: SampledImageArray, index: Val(u32), uv: Val(Vec2)) Error!Val(Vec4) {
        return (try a.at(index)).sample(uv);
    }
};

/// One loaded (non-uniform) combined image sampler.
pub const SampledImage = struct {
    s: *Shader,
    id: Id,

    /// `textureLod(t, uv, 0)`: explicit LOD, so it is valid in
    /// non-uniform control flow.
    pub fn sample(t: SampledImage, uv: Val(Vec2)) Error!Val(Vec4) {
        const s = t.s;
        const zero = try s.m.constant(try s.m.typeFloat(32), 0.0);
        const lod: spec.ImageOperands = .{ .Lod = true };
        return s.op(Vec4, .OpImageSampleExplicitLod, &.{ t.id.word(), uv.id.word(), @bitCast(lod), zero.word() });
    }

    /// `vec2(textureSize(t, 0))` in texels.
    pub fn size(t: SampledImage) Error!Val(Vec2) {
        const s = t.s;
        try s.m.capability(.ImageQuery);
        const img_t = try s.m.typeImage(.{ .sampled_type = try s.m.typeFloat(32) });
        const img = try s.f.result(.OpImage, img_t, &.{t.id.word()});
        try s.m.decorate(img, .NonUniform);
        const lod = try s.m.constant(try s.m.typeInt(32, true), 0);
        const isz = try s.op(@Vector(2, i32), .OpImageQuerySizeLod, &.{ img.word(), lod.word() });
        return isz.to(f32);
    }
};

/// An `if` under construction (see `Shader.beginIf`).
pub const If = struct {
    s: *Shader,
    merge: Id,
    else_label: Id,
    then_end: Id = .none,
    then_val: Id = .none,

    /// Ends the `then` block with value `v` (or `null` for none) and
    /// starts the `else` block.
    pub fn orElse(b: *If, v: anytype) Error!void {
        b.then_val = idOf(v);
        b.then_end = b.s.block;
        try b.s.f.op(.OpBranch, &.{b.merge.word()});
        try b.s.startBlock(b.else_label);
    }

    /// Ends the `else` block with `v` and returns the merged value.
    pub fn end(b: *If, comptime T: type, v: Val(T)) Error!Val(T) {
        const else_end = b.s.block;
        try b.s.f.op(.OpBranch, &.{b.merge.word()});
        try b.s.startBlock(b.merge);
        return b.s.op(T, .OpPhi, &.{ b.then_val.word(), b.then_end.word(), v.id.word(), else_end.word() });
    }

    /// Ends an `if` without a value.
    pub fn endVoid(b: *If) Error!void {
        try b.s.f.op(.OpBranch, &.{b.merge.word()});
        try b.s.startBlock(b.merge);
    }
};

fn idOf(v: anytype) Id {
    return if (@TypeOf(v) == @TypeOf(null)) .none else v.id;
}

/// A `switch` producing a `T` (see `Shader.beginSwitch`).
pub fn Switch(comptime T: type) type {
    return struct {
        s: *Shader,
        merge: Id,
        labels: []Id,
        default_label: Id,
        next: usize = 0,
        incoming: std.ArrayList(u32) = .empty,

        const Self = @This();

        /// Ends the current case with value `v` and starts the next case
        /// (or the default after the last one).
        pub fn case(sw: *Self, v: Val(T)) Error!void {
            const gpa = sw.s.m.gpa;
            try sw.incoming.appendSlice(gpa, &.{ v.id.word(), sw.s.block.word() });
            try sw.s.f.op(.OpBranch, &.{sw.merge.word()});
            sw.next += 1;
            try sw.s.startBlock(if (sw.next < sw.labels.len) sw.labels[sw.next] else sw.default_label);
        }

        /// Ends the default case with `v` and returns the merged value.
        pub fn end(sw: *Self, v: Val(T)) Error!Val(T) {
            std.debug.assert(sw.next == sw.labels.len);
            const gpa = sw.s.m.gpa;
            defer sw.incoming.deinit(gpa);
            defer gpa.free(sw.labels);
            try sw.incoming.appendSlice(gpa, &.{ v.id.word(), sw.s.block.word() });
            try sw.s.f.op(.OpBranch, &.{sw.merge.word()});
            try sw.s.startBlock(sw.merge);
            return sw.s.op(T, .OpPhi, sw.incoming.items);
        }
    };
}

pub const Shader = struct {
    m: Module,
    stage: Stage,
    f: *Function,
    /// The current block's label.
    block: Id,
    interface: std.ArrayList(Id) = .empty,
    /// Zig types (by name) to SPIR-V type ids for structs and arrays.
    composite_types: std.StringHashMapUnmanaged(Id) = .empty,
    /// Ids already decorated NonUniform (a second decoration is invalid).
    non_uniform: std.AutoHashMapUnmanaged(Id, void) = .empty,

    pub fn init(gpa: std.mem.Allocator, stage: Stage) Error!*Shader {
        const s = try gpa.create(Shader);
        errdefer gpa.destroy(s);
        s.* = .{ .m = .init(gpa, .{}), .stage = stage, .f = undefined, .block = .none };
        s.f = try s.m.function(try s.m.typeVoid(), &.{});
        try s.m.name(s.f.id, "main");
        try s.startBlock(s.m.newId());
        return s;
    }

    pub fn deinit(s: *Shader) void {
        const gpa = s.m.gpa;
        s.interface.deinit(gpa);
        s.composite_types.deinit(gpa);
        s.non_uniform.deinit(gpa);
        s.m.deinit();
        gpa.destroy(s);
    }

    /// Returns from `main` and produces the module words (owned).
    pub fn finish(s: *Shader) Error![]u32 {
        try s.f.op(.OpReturn, &.{});
        const model: spec.ExecutionModel = switch (s.stage) {
            .vertex => .Vertex,
            .fragment => .Fragment,
        };
        try s.m.entryPoint(model, s.f, "main", s.interface.items);
        if (s.stage == .fragment) try s.m.executionMode(s.f, .OriginUpperLeft);
        return s.m.finish();
    }

    /// Decorates `id` NonUniform once.
    pub fn nonUniform(s: *Shader, id: Id) Error!void {
        if ((try s.non_uniform.getOrPut(s.m.gpa, id)).found_existing) return;
        try s.m.decorate(id, .NonUniform);
    }

    fn startBlock(s: *Shader, l: Id) Error!void {
        try s.f.label(l);
        s.block = l;
    }

    /// `%r = op %T operands` as a `Val(T)`.
    pub fn op(s: *Shader, comptime T: type, opcode: Opcode, operands: []const u32) Error!Val(T) {
        return .{ .s = s, .id = try s.f.result(opcode, try s.typeOf(T), operands) };
    }

    /// The SPIR-V type of a DSL value type, extern struct or array.
    pub fn typeOf(s: *Shader, comptime T: type) Error!Id {
        const m = &s.m;
        switch (@typeInfo(T)) {
            .vector => |v| return m.typeVector(try s.typeOf(v.child), v.len),
            .@"struct", .array => {},
            .void => return m.typeVoid(),
            else => return switch (T) {
                f32 => m.typeFloat(32),
                u32 => m.typeInt(32, false),
                i32 => m.typeInt(32, true),
                bool => m.typeBool(),
                else => @compileError("no SPIR-V type for " ++ @typeName(T)),
            },
        }
        if (s.composite_types.get(@typeName(T))) |hit| return hit;
        const t = switch (@typeInfo(T)) {
            .array => |a| blk: {
                // Arrays of numbers inside blocks are vectors (see FieldType).
                break :blk try s.typeOf(@Vector(a.len, a.child));
            },
            .@"struct" => |st| blk: {
                if (st.layout != .@"extern") @compileError("buffer structs must be extern: " ++ @typeName(T));
                var members: [st.fields.len]Id = undefined;
                inline for (st.fields, 0..) |fld, i| members[i] = try s.typeOf(FieldType(T, fld.name));
                const id = try m.typeStruct(&members);
                inline for (st.fields, 0..) |fld, i| {
                    try m.memberDecorate(id, i, .{ .Offset = @offsetOf(T, fld.name) });
                    try m.memberName(id, i, fld.name);
                }
                try m.name(id, shortName(@typeName(T)));
                break :blk id;
            },
            else => unreachable,
        };
        try s.composite_types.put(m.gpa, @typeName(T), t);
        return t;
    }

    fn shortName(comptime full: []const u8) []const u8 {
        const dot = comptime std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
        return full[dot + 1 ..];
    }

    /// A constant of type `T` (scalar or vector of identical lanes or an
    /// array literal).
    pub fn c(s: *Shader, comptime T: type, value: anytype) Error!Val(T) {
        const ty = try s.typeOf(T);
        if (comptime lanes(T) == 1) return .{ .s = s, .id = try s.m.constant(ty, value) };
        const E = Elem(T);
        const et = try s.typeOf(E);
        var parts: [4]Id = undefined;
        inline for (0..lanes(T)) |i| {
            const v = if (@typeInfo(@TypeOf(value)) == .array or @typeInfo(@TypeOf(value)) == .vector or @typeInfo(@TypeOf(value)) == .@"struct") value[i] else value;
            parts[i] = try s.m.constant(et, @as(E, v));
        }
        return .{ .s = s, .id = try s.m.constantComposite(ty, parts[0..lanes(T)]) };
    }

    /// A vector from components.
    pub fn vec(s: *Shader, comptime T: type, parts: anytype) Error!Val(T) {
        var words: [4]u32 = undefined;
        inline for (parts, 0..) |p, i| words[i] = p.id.word();
        return s.op(T, .OpCompositeConstruct, words[0..parts.len]);
    }

    /// A vector with every lane `v`.
    pub fn splat(s: *Shader, comptime T: type, v: Val(Elem(T))) Error!Val(T) {
        var words: [4]u32 = undefined;
        inline for (0..lanes(T)) |i| words[i] = v.id.word();
        return s.op(T, .OpCompositeConstruct, words[0..lanes(T)]);
    }

    fn interfaceVar(s: *Shader, comptime T: type, sc: spec.StorageClass) Error!Id {
        const v = try s.m.variable(try s.m.typePointer(sc, try s.typeOf(T)), sc);
        try s.interface.append(s.m.gpa, v);
        return v;
    }

    /// A stage input at `loc` (loaded here); `flat` for integers.
    pub fn input(s: *Shader, comptime T: type, loc: u32, flat: bool) Error!Val(T) {
        const v = try s.interfaceVar(T, .Input);
        try s.m.decorate(v, .{ .Location = loc });
        if (flat) try s.m.decorate(v, .Flat);
        return s.op(T, .OpLoad, &.{v.word()});
    }

    /// A stage output at `loc`; `index` 1 is the dual-source second output.
    pub fn output(s: *Shader, comptime T: type, loc: u32, index: u1) Error!Ptr(T) {
        const v = try s.interfaceVar(T, .Output);
        try s.m.decorate(v, .{ .Location = loc });
        if (index != 0) try s.m.decorate(v, .{ .Index = index });
        if (s.stage == .vertex and scalarOf(T) != .f32) try s.m.decorate(v, .Flat);
        return .{ .s = s, .id = v };
    }

    pub const InBuiltIn = enum { VertexIndex, InstanceIndex, FragCoord };

    fn InBuiltInType(comptime b: InBuiltIn) type {
        return switch (b) {
            .VertexIndex, .InstanceIndex => u32,
            .FragCoord => Vec4,
        };
    }

    /// An input built-in (loaded here).
    pub fn builtin(s: *Shader, comptime b: InBuiltIn) Error!Val(InBuiltInType(b)) {
        const T = InBuiltInType(b);
        const v = try s.interfaceVar(T, .Input);
        try s.m.decorate(v, .{ .BuiltIn = @field(spec.BuiltIn, @tagName(b)) });
        return s.op(T, .OpLoad, &.{v.word()});
    }

    /// The vertex `Position` output.
    pub fn position(s: *Shader) Error!Ptr(Vec4) {
        const v = try s.interfaceVar(Vec4, .Output);
        try s.m.decorate(v, .{ .BuiltIn = .Position });
        return .{ .s = s, .id = v };
    }

    /// `readonly buffer { E items[]; }` at (set, binding).
    pub fn storageBuffer(s: *Shader, comptime E: type, set: u32, binding: u32) Error!StorageArray(E) {
        const m = &s.m;
        const elem = try s.typeOf(E);
        const arr = try m.typeRuntimeArray(elem);
        try m.decorate(arr, .{ .ArrayStride = @sizeOf(E) });
        const block = try m.typeStruct(&.{arr});
        try m.decorate(block, .Block);
        try m.memberDecorate(block, 0, .{ .Offset = 0 });
        try m.memberDecorate(block, 0, .NonWritable);
        const v = try m.variable(try m.typePointer(.StorageBuffer, block), .StorageBuffer);
        try m.decorate(v, .{ .DescriptorSet = set });
        try m.decorate(v, .{ .Binding = binding });
        return .{ .s = s, .var_id = v };
    }

    /// The push-constant block of extern struct type `T`.
    pub fn pushConstant(s: *Shader, comptime T: type) Error!Fields(T) {
        const m = &s.m;
        const st = try s.typeOf(T);
        try m.decorate(st, .Block);
        const v = try m.variable(try m.typePointer(.PushConstant, st), .PushConstant);
        try m.name(v, "pc");
        return .{ .s = s, .base = v, .sc = .PushConstant, .prefix = undefined, .prefix_len = 0 };
    }

    /// `uniform sampler2D textures[]` at (set, binding), for non-uniform
    /// indexing (adds the descriptor-indexing capabilities).
    pub fn sampledImageArray(s: *Shader, set: u32, binding: u32) Error!SampledImageArray {
        const m = &s.m;
        try m.capability(.RuntimeDescriptorArray);
        try m.capability(.ShaderNonUniform);
        try m.capability(.SampledImageArrayNonUniformIndexing);
        try s.extension("SPV_EXT_descriptor_indexing");
        const img = try m.typeImage(.{ .sampled_type = try m.typeFloat(32) });
        const si = try m.typeSampledImage(img);
        const arr = try m.typeRuntimeArray(si);
        const v = try m.variable(try m.typePointer(.UniformConstant, arr), .UniformConstant);
        try m.decorate(v, .{ .DescriptorSet = set });
        try m.decorate(v, .{ .Binding = binding });
        try m.name(v, "textures");
        return .{ .s = s, .var_id = v, .sampled_image_t = si };
    }

    fn extension(s: *Shader, name: []const u8) Error!void {
        const m = &s.m;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try builder.appendString(m.gpa, &words, name);
        // Deduplicate against what is already there.
        const sec = m.sections[@intFromEnum(builder.Section.extension)].items;
        var i: usize = 0;
        while (i < sec.len) : (i += sec[i] >> 16) {
            if (std.mem.eql(u32, sec[i + 1 .. i + (sec[i] >> 16)], words.items)) return;
        }
        try m.raw(.extension, .OpExtension, words.items);
    }

    /// A Function-storage variable (declared at the start of `main`).
    pub fn local(s: *Shader, comptime T: type) Error!Ptr(T) {
        const p = try s.f.local(try s.m.typePointer(.Function, try s.typeOf(T)));
        return .{ .s = s, .id = p };
    }

    /// Starts `if (cond)`: code emitted next is the `then` block until
    /// `orElse`, then the `else` block until `end`.
    pub fn beginIf(s: *Shader, cond: Val(bool)) Error!If {
        const merge = s.m.newId();
        const then_l = s.m.newId();
        const else_l = s.m.newId();
        try s.f.op(.OpSelectionMerge, &.{ merge.word(), 0 });
        try s.f.op(.OpBranchConditional, &.{ cond.id.word(), then_l.word(), else_l.word() });
        try s.startBlock(then_l);
        return .{ .s = s, .merge = merge, .else_label = else_l };
    }

    /// Starts `switch (sel)` with one case per value in `cases`; code
    /// emitted next is the first case. Close each case with `case`, then
    /// the default with `end`.
    pub fn beginSwitch(s: *Shader, comptime T: type, sel: Val(u32), cases: []const u32) Error!Switch(T) {
        const gpa = s.m.gpa;
        const merge = s.m.newId();
        const default_l = s.m.newId();
        const labels = try gpa.alloc(Id, cases.len);
        errdefer gpa.free(labels);
        for (labels) |*l| l.* = s.m.newId();
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        try words.appendSlice(gpa, &.{ sel.id.word(), default_l.word() });
        for (cases, labels) |v, l| try words.appendSlice(gpa, &.{ v, l.word() });
        try s.f.op(.OpSelectionMerge, &.{ merge.word(), 0 });
        try s.f.op(.OpSwitch, words.items);
        try s.startBlock(if (labels.len > 0) labels[0] else default_l);
        return .{ .s = s, .merge = merge, .labels = labels, .default_label = default_l };
    }

    /// GLSL `unpackUnorm4x8`: u32 RGBA8 to vec4 in 0..1.
    pub fn unpackUnorm4x8(s: *Shader, v: Val(u32)) Error!Val(Vec4) {
        return .{ .s = s, .id = try s.f.glsl(try s.typeOf(Vec4), .UnpackUnorm4x8, &.{v.id}) };
    }

    /// GLSL `unpackHalf2x16`: two f16 in a u32 to vec2.
    pub fn unpackHalf2x16(s: *Shader, v: Val(u32)) Error!Val(Vec2) {
        return .{ .s = s, .id = try s.f.glsl(try s.typeOf(Vec2), .UnpackHalf2x16, &.{v.id}) };
    }
};

// ---------------------------------------------------------------- tests

const validate = @import("validate.zig");

/// The words of the last instruction emitted into `main`'s body.
fn lastInst(s: *Shader) []const u32 {
    const body = s.f.body.items;
    var i: usize = 0;
    var last: usize = 0;
    while (i < body.len) : (i += body[i] >> 16) last = i;
    return body[last .. last + (body[last] >> 16)];
}

fn expectOp(s: *Shader, op: Opcode) !void {
    try std.testing.expectEqual(op, @as(Opcode, @enumFromInt(@as(u16, @truncate(lastInst(s)[0])))));
}

fn expectGlsl(s: *Shader, inst: spec.GlslStd450) !void {
    const w = lastInst(s);
    try expectOp(s, .OpExtInst);
    try std.testing.expectEqual(s.m.glsl.word(), w[3]);
    try std.testing.expectEqual(@intFromEnum(inst), w[4]);
}

fn expectValid(s: *Shader) !void {
    const gpa = std.testing.allocator;
    const words = try s.finish();
    defer gpa.free(words);
    const issues = try validate.validate(gpa, words, .vulkan_1_2);
    defer validate.freeIssues(gpa, issues);
    for (issues) |i| std.debug.print("{f}\n", .{i});
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "dsl: arithmetic picks float and integer ops" {
    const s = try Shader.init(std.testing.allocator, .fragment);
    defer s.deinit();
    const a = try s.c(Vec2, 1.0);
    const b = try s.c(Vec2, .{ 2.0, 3.0 });
    _ = try a.add(b);
    try expectOp(s, .OpFAdd);
    _ = try a.mul(b);
    try expectOp(s, .OpFMul);
    _ = try a.scale(try s.c(f32, 2.0));
    try expectOp(s, .OpVectorTimesScalar);
    const u = try s.c(u32, 7);
    _ = try u.add(u);
    try expectOp(s, .OpIAdd);
    _ = try u.div(u);
    try expectOp(s, .OpUDiv);
    _ = try u.shr(try s.c(u32, 2));
    try expectOp(s, .OpShiftRightLogical);
    _ = try u.@"and"(u);
    try expectOp(s, .OpBitwiseAnd);
    _ = try u.to(f32);
    try expectOp(s, .OpConvertUToF);
    _ = try a.dot(b);
    try expectOp(s, .OpDot);
    _ = try a.lt(b);
    try expectOp(s, .OpFOrdLessThan);
    _ = try b.swizzle("yx");
    try expectOp(s, .OpVectorShuffle);
    _ = try b.y();
    try expectOp(s, .OpCompositeExtract);
    try expectValid(s);
}

test "dsl: mix emits OpExtInst FMix (and the other built-ins)" {
    const s = try Shader.init(std.testing.allocator, .fragment);
    defer s.deinit();
    const a = try s.c(f32, 0.25);
    _ = try a.mix(a, a);
    try expectGlsl(s, .FMix);
    _ = try a.clamp(a, a);
    try expectGlsl(s, .FClamp);
    _ = try a.smoothstep(a, a);
    try expectGlsl(s, .SmoothStep);
    _ = try a.abs();
    try expectGlsl(s, .FAbs);
    _ = try a.max(a);
    try expectGlsl(s, .FMax);
    _ = try a.min(a);
    try expectGlsl(s, .FMin);
    _ = try a.pow(a);
    try expectGlsl(s, .Pow);
    _ = try a.sqrt();
    try expectGlsl(s, .Sqrt);
    _ = try a.exp();
    try expectGlsl(s, .Exp);
    _ = try (try s.c(Vec2, 1.0)).length();
    try expectGlsl(s, .Length);
    _ = try s.unpackUnorm4x8(try s.c(u32, 0xff00ff00));
    try expectGlsl(s, .UnpackUnorm4x8);
    _ = try s.unpackHalf2x16(try s.c(u32, 0x3c00_3c00));
    try expectGlsl(s, .UnpackHalf2x16);
    try expectValid(s);
}

test "dsl: ifElse emits merge + phi" {
    const s = try Shader.init(std.testing.allocator, .fragment);
    defer s.deinit();
    const out = try s.output(Vec4, 0, 0);
    const cond = try (try s.c(f32, 1.0)).lt(try s.c(f32, 2.0));
    var br = try s.beginIf(cond);
    const t = try (try s.c(Vec4, 1.0)).scale(try s.c(f32, 0.5));
    try br.orElse(t);
    const e = try s.c(Vec4, 0.0);
    const r = try br.end(Vec4, e);
    try expectOp(s, .OpPhi);
    try out.store(r);
    try expectValid(s);
    // The merge precedes the conditional branch.
    const body = s.f.body.items;
    var i: usize = 0;
    var prev: Opcode = .OpNop;
    while (i < body.len) : (i += body[i] >> 16) {
        const op: Opcode = @enumFromInt(@as(u16, @truncate(body[i])));
        if (op == .OpBranchConditional) try std.testing.expectEqual(Opcode.OpSelectionMerge, prev);
        prev = op;
    }
}

test "dsl: switchOn emits OpSwitch and one phi" {
    const s = try Shader.init(std.testing.allocator, .fragment);
    defer s.deinit();
    const out = try s.output(f32, 0, 0);
    var sw = try s.beginSwitch(f32, try s.c(u32, 1), &.{ 0, 1, 2 });
    try sw.case(try s.c(f32, 0.0));
    try sw.case(try s.c(f32, 1.0));
    try sw.case(try s.c(f32, 2.0));
    const r = try sw.end(try s.c(f32, -1.0));
    try expectOp(s, .OpPhi);
    // Four incoming (value, block) pairs.
    try std.testing.expectEqual(@as(usize, 3 + 8), lastInst(s).len);
    try out.store(r);
    try expectValid(s);
}

const TestElem = extern struct {
    bounds: [4]f32,
    color: u32,
    radii: [2]u32,
    kind: u32,
};

test "dsl: storageBuffer offsets from extern struct" {
    const s = try Shader.init(std.testing.allocator, .vertex);
    defer s.deinit();
    const buf = try s.storageBuffer(TestElem, 0, 1);
    const idx = try s.builtin(.InstanceIndex);
    const e = try buf.at(idx);
    const bounds = try e.get("bounds");
    _ = try e.get("radii");
    const pos = try s.position();
    try pos.store(bounds);
    try expectValid(s);
    // Member offsets come from @offsetOf.
    const ann = s.m.sections[@intFromEnum(builder.Section.annotation)].items;
    var offsets: [4]u32 = @splat(999);
    var i: usize = 0;
    while (i < ann.len) : (i += ann[i] >> 16) {
        if (@as(u16, @truncate(ann[i])) == @intFromEnum(Opcode.OpMemberDecorate) and ann[i + 3] == @intFromEnum(spec.Decoration.Offset) and ann[i + 2] < 4 and ann[i + 1] != 0) {
            offsets[ann[i + 2]] = ann[i + 4];
        }
    }
    try std.testing.expectEqual([4]u32{ 0, 16, 20, 28 }, offsets);
}

test "dsl: sampled image array is decorated NonUniform" {
    const s = try Shader.init(std.testing.allocator, .fragment);
    defer s.deinit();
    const tex = try s.sampledImageArray(0, 2);
    const out = try s.output(Vec4, 0, 0);
    const idx = try s.input(u32, 0, true);
    const uv = try s.input(Vec2, 1, false);
    try out.store(try tex.sample(idx, uv));
    try expectOp(s, .OpStore);
    const sz = try (try tex.at(idx)).size();
    try expectOp(s, .OpConvertSToF);
    _ = try tex.at(idx); // the index is decorated only once
    _ = sz;
    try expectValid(s);
}
