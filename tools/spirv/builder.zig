//! The typed SPIR-V module builder (E02.F05.S01.T01, ADR-E02-004).
//!
//! Instructions go into one word buffer per logical section (SPIR-V spec
//! §2.4); `finish` concatenates them behind the header. Non-aggregate
//! types and constants are hash-consed, so `typeFloat(32)` always returns
//! the same id; structs and arrays are not, since two of them may carry
//! different decorations.

const std = @import("std");
const spec = @import("spec.zig");

pub const Opcode = spec.Opcode;
pub const StorageClass = spec.StorageClass;
pub const Capability = spec.Capability;
pub const ExecutionModel = spec.ExecutionModel;
pub const DecorationArg = spec.DecorationArg;
pub const ExecutionModeArg = spec.ExecutionModeArg;

/// A result id. `none` (0) is never a valid id.
pub const Id = enum(u32) {
    none = 0,
    _,

    pub fn word(self: Id) u32 {
        return @intFromEnum(self);
    }
};

pub const Version = enum(u32) {
    v1_0 = 0x0001_0000,
    v1_3 = 0x0001_0300,
    v1_4 = 0x0001_0400,
    v1_5 = 0x0001_0500,
    v1_6 = 0x0001_0600,

    pub fn minor(self: Version) u8 {
        return @truncate(@intFromEnum(self) >> 8);
    }
};

pub const Options = struct {
    version: Version = .v1_3,
    caps: []const Capability = &.{.Shader},
    extensions: []const []const u8 = &.{},
};

/// The logical layout of a module, in order (spec §2.4).
pub const Section = enum {
    capability,
    extension,
    ext_inst_import,
    memory_model,
    entry_point,
    execution_mode,
    debug_string,
    debug_name,
    annotation,
    global,
    function,
};

pub const Dim = spec.Dim;
pub const ImageFormat = spec.ImageFormat;

/// `OpTypeImage` operands. `sampled` 1 = used with a sampler.
pub const ImageDesc = struct {
    sampled_type: Id,
    dim: Dim = .@"2D",
    depth: u32 = 0,
    arrayed: bool = false,
    ms: bool = false,
    sampled: u32 = 1,
    format: ImageFormat = .Unknown,
};

/// What the builder knows about a type id (for constants and the DSL).
pub const TypeInfo = union(enum) {
    void,
    bool,
    int: struct { bits: u8, signed: bool },
    float: u8,
    vector: struct { comp: Id, n: u8 },
    pointer: struct { sc: StorageClass, pointee: Id },
    other,
};

pub const Error = error{OutOfMemory};

const EntryPoint = struct {
    model: ExecutionModel,
    func: Id,
    name: []const u8,
    interface: []const Id,
};

pub const Module = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    next_id: u32 = 1,
    sections: [std.meta.fields(Section).len]std.ArrayList(u32) = @splat(.empty),
    /// Hash-consed type and constant instructions (opcode + operands
    /// without the result id) to their ids.
    cache: std.StringHashMapUnmanaged(Id) = .empty,
    types: std.AutoHashMapUnmanaged(Id, TypeInfo) = .empty,
    /// Global variables and their storage classes, for 1.4+ interfaces.
    globals: std.ArrayList(struct { Id, StorageClass }) = .empty,
    entries: std.ArrayList(EntryPoint) = .empty,
    functions: std.ArrayList(*Function) = .empty,
    caps: std.ArrayList(Capability) = .empty,
    glsl: Id = .none,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, opts: Options) Module {
        return .{ .gpa = gpa, .opts = opts, .arena = .init(gpa) };
    }

    pub fn deinit(m: *Module) void {
        for (&m.sections) |*s| s.deinit(m.gpa);
        m.cache.deinit(m.gpa);
        m.types.deinit(m.gpa);
        m.globals.deinit(m.gpa);
        m.entries.deinit(m.gpa);
        for (m.functions.items) |f| f.deinit();
        m.functions.deinit(m.gpa);
        m.caps.deinit(m.gpa);
        m.arena.deinit();
        m.* = undefined;
    }

    pub fn newId(m: *Module) Id {
        defer m.next_id += 1;
        return @enumFromInt(m.next_id);
    }

    /// Appends one instruction to `section` (raw: no checks).
    pub fn raw(m: *Module, section: Section, op: Opcode, operands: []const u32) Error!void {
        try encode(m.gpa, &m.sections[@intFromEnum(section)], op, operands);
    }

    /// Adds a capability (deduplicated).
    pub fn capability(m: *Module, cap: Capability) Error!void {
        for (m.caps.items) |c| if (c == cap) return;
        try m.caps.append(m.gpa, cap);
    }

    pub fn typeInfo(m: *const Module, ty: Id) TypeInfo {
        return m.types.get(ty) orelse .other;
    }

    /// A hash-consed global-section instruction `op %result operands`.
    fn cached(m: *Module, op: Opcode, operands: []const u32, info: TypeInfo) Error!Id {
        return m.cachedTyped(op, null, operands, info);
    }

    fn cachedTyped(m: *Module, op: Opcode, ty: ?Id, operands: []const u32, info: TypeInfo) Error!Id {
        var key_words: [64]u32 = undefined;
        std.debug.assert(operands.len + 2 < key_words.len);
        key_words[0] = @intFromEnum(op);
        key_words[1] = if (ty) |t| t.word() else 0;
        @memcpy(key_words[2..][0..operands.len], operands);
        const key = std.mem.sliceAsBytes(key_words[0 .. operands.len + 2]);
        if (m.cache.get(key)) |hit| return hit;
        const r = try m.globalResult(op, ty, operands);
        try m.cache.put(m.gpa, try m.arena.allocator().dupe(u8, key), r);
        if (info != .other) try m.types.put(m.gpa, r, info);
        return r;
    }

    /// `op [%type] %new operands` in the global section.
    fn globalResult(m: *Module, op: Opcode, ty: ?Id, operands: []const u32) Error!Id {
        const r = m.newId();
        const s = &m.sections[@intFromEnum(Section.global)];
        const n: u32 = @intCast(2 + @as(usize, @intFromBool(ty != null)) + operands.len);
        try s.append(m.gpa, n << 16 | @intFromEnum(op));
        if (ty) |t| try s.append(m.gpa, t.word());
        try s.append(m.gpa, r.word());
        try s.appendSlice(m.gpa, operands);
        return r;
    }

    pub fn typeVoid(m: *Module) Error!Id {
        return m.cached(.OpTypeVoid, &.{}, .void);
    }
    pub fn typeBool(m: *Module) Error!Id {
        return m.cached(.OpTypeBool, &.{}, .bool);
    }
    pub fn typeInt(m: *Module, bits: u8, signed: bool) Error!Id {
        return m.cached(.OpTypeInt, &.{ bits, @intFromBool(signed) }, .{ .int = .{ .bits = bits, .signed = signed } });
    }
    pub fn typeFloat(m: *Module, bits: u8) Error!Id {
        return m.cached(.OpTypeFloat, &.{bits}, .{ .float = bits });
    }
    pub fn typeVector(m: *Module, comp: Id, n: u8) Error!Id {
        return m.cached(.OpTypeVector, &.{ comp.word(), n }, .{ .vector = .{ .comp = comp, .n = n } });
    }
    pub fn typePointer(m: *Module, sc: StorageClass, pointee: Id) Error!Id {
        return m.cached(.OpTypePointer, &.{ @intFromEnum(sc), pointee.word() }, .{ .pointer = .{ .sc = sc, .pointee = pointee } });
    }
    pub fn typeFunction(m: *Module, ret: Id, params: []const Id) Error!Id {
        var words: [32]u32 = undefined;
        words[0] = ret.word();
        for (params, 1..) |p, i| words[i] = p.word();
        return m.cached(.OpTypeFunction, words[0 .. params.len + 1], .other);
    }
    pub fn typeImage(m: *Module, d: ImageDesc) Error!Id {
        return m.cached(.OpTypeImage, &.{ d.sampled_type.word(), @intFromEnum(d.dim), d.depth, @intFromBool(d.arrayed), @intFromBool(d.ms), d.sampled, @intFromEnum(d.format) }, .other);
    }
    pub fn typeSampledImage(m: *Module, img: Id) Error!Id {
        return m.cached(.OpTypeSampledImage, &.{img.word()}, .other);
    }
    pub fn typeSampler(m: *Module) Error!Id {
        return m.cached(.OpTypeSampler, &.{}, .other);
    }
    /// Not hash-consed (decorations make each struct distinct).
    pub fn typeStruct(m: *Module, members: []const Id) Error!Id {
        var words: [64]u32 = undefined;
        for (members, 0..) |x, i| words[i] = x.word();
        return m.globalResult(.OpTypeStruct, null, words[0..members.len]);
    }
    /// Not hash-consed (it carries an ArrayStride decoration).
    pub fn typeRuntimeArray(m: *Module, elem: Id) Error!Id {
        return m.globalResult(.OpTypeRuntimeArray, null, &.{elem.word()});
    }
    pub fn typeArray(m: *Module, elem: Id, len: u32) Error!Id {
        const u = try m.typeInt(32, false);
        return m.globalResult(.OpTypeArray, null, &.{ elem.word(), (try m.constant(u, len)).word() });
    }

    /// A scalar constant of type `ty` (bool, int or float type).
    pub fn constant(m: *Module, ty: Id, value: anytype) Error!Id {
        const T = @TypeOf(value);
        const info = m.typeInfo(ty);
        if (T == bool) {
            std.debug.assert(info == .bool);
            return m.cachedTyped(if (value) .OpConstantTrue else .OpConstantFalse, ty, &.{}, .other);
        }
        const is_float = comptime @typeInfo(T) == .float or T == comptime_float;
        switch (info) {
            .int => |i| {
                if (comptime is_float) unreachable else {
                    const v: i64 = @intCast(value);
                    const bits: u64 = @bitCast(v);
                    if (i.bits <= 32) return m.cachedTyped(.OpConstant, ty, &.{@truncate(bits)}, .other);
                    return m.cachedTyped(.OpConstant, ty, &.{ @truncate(bits), @truncate(bits >> 32) }, .other);
                }
            },
            .float => |bits| {
                const f: f64 = if (comptime is_float) value else @floatFromInt(value);
                if (bits == 64) {
                    const w: u64 = @bitCast(f);
                    return m.cachedTyped(.OpConstant, ty, &.{ @truncate(w), @truncate(w >> 32) }, .other);
                }
                const w: u32 = if (bits == 16) @as(u16, @bitCast(@as(f16, @floatCast(f)))) else @bitCast(@as(f32, @floatCast(f)));
                return m.cachedTyped(.OpConstant, ty, &.{w}, .other);
            },
            else => unreachable,
        }
    }

    pub fn constantComposite(m: *Module, ty: Id, parts: []const Id) Error!Id {
        var words: [32]u32 = undefined;
        for (parts, 0..) |p, i| words[i] = p.word();
        return m.cachedTyped(.OpConstantComposite, ty, words[0..parts.len], .other);
    }

    pub fn constantNull(m: *Module, ty: Id) Error!Id {
        return m.cachedTyped(.OpConstantNull, ty, &.{}, .other);
    }

    /// A global `OpVariable` (`ptr_ty` must be a pointer to `sc`).
    pub fn variable(m: *Module, ptr_ty: Id, sc: StorageClass) Error!Id {
        const v = try m.globalResult(.OpVariable, ptr_ty, &.{@intFromEnum(sc)});
        try m.globals.append(m.gpa, .{ v, sc });
        try m.types.put(m.gpa, v, .{ .pointer = .{ .sc = sc, .pointee = switch (m.typeInfo(ptr_ty)) {
            .pointer => |p| p.pointee,
            else => .none,
        } } });
        return v;
    }

    pub fn decorate(m: *Module, target: Id, d: DecorationArg) Error!void {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try words.appendSlice(m.gpa, &.{ target.word(), @intFromEnum(d.tag()) });
        switch (d) {
            inline else => |payload| try encodeArg(m.gpa, &words, payload),
        }
        try m.raw(.annotation, .OpDecorate, words.items);
    }

    pub fn memberDecorate(m: *Module, st: Id, member: u32, d: DecorationArg) Error!void {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try words.appendSlice(m.gpa, &.{ st.word(), member, @intFromEnum(d.tag()) });
        switch (d) {
            inline else => |payload| try encodeArg(m.gpa, &words, payload),
        }
        try m.raw(.annotation, .OpMemberDecorate, words.items);
    }

    pub fn name(m: *Module, target: Id, n: []const u8) Error!void {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try words.append(m.gpa, target.word());
        try appendString(m.gpa, &words, n);
        try m.raw(.debug_name, .OpName, words.items);
    }

    pub fn memberName(m: *Module, st: Id, member: u32, n: []const u8) Error!void {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try words.appendSlice(m.gpa, &.{ st.word(), member });
        try appendString(m.gpa, &words, n);
        try m.raw(.debug_name, .OpMemberName, words.items);
    }

    /// The `GLSL.std.450` import (added on first use).
    pub fn glslStd450(m: *Module) Error!Id {
        if (m.glsl != .none) return m.glsl;
        m.glsl = m.newId();
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try words.append(m.gpa, m.glsl.word());
        try appendString(m.gpa, &words, "GLSL.std.450");
        try m.raw(.ext_inst_import, .OpExtInstImport, words.items);
        return m.glsl;
    }

    /// Starts a function; emit its body through the returned `Function`.
    pub fn function(m: *Module, ret: Id, params: []const Id) Error!*Function {
        const f = try m.gpa.create(Function);
        errdefer m.gpa.destroy(f);
        f.* = .{ .m = m, .id = m.newId(), .ret = ret, .ty = try m.typeFunction(ret, params) };
        try m.functions.append(m.gpa, f);
        for (params) |p| try f.params.append(m.gpa, .{ p, m.newId() });
        return f;
    }

    /// Declares an entry point. For SPIR-V < 1.4 `interface` lists the
    /// Input/Output variables; for 1.4+ every global is added at `finish`.
    pub fn entryPoint(m: *Module, model: ExecutionModel, f: *Function, n: []const u8, interface: []const Id) Error!void {
        const a = m.arena.allocator();
        try m.entries.append(m.gpa, .{ .model = model, .func = f.id, .name = try a.dupe(u8, n), .interface = try a.dupe(Id, interface) });
    }

    pub fn executionMode(m: *Module, f: *Function, mode: ExecutionModeArg) Error!void {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(m.gpa);
        try words.appendSlice(m.gpa, &.{ f.id.word(), @intFromEnum(mode.tag()) });
        switch (mode) {
            inline else => |payload| try encodeArg(m.gpa, &words, payload),
        }
        try m.raw(.execution_mode, .OpExecutionMode, words.items);
    }

    /// The module words: header, then the sections in canonical order.
    /// The caller owns the slice. Structural validation is `validate.zig`.
    pub fn finish(m: *Module) Error![]u32 {
        const gpa = m.gpa;
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(gpa);
        for (m.opts.caps) |c| try m.capability(c);
        for (m.caps.items) |c| try encode(gpa, &out, .OpCapability, &.{@intFromEnum(c)});
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        for (m.opts.extensions) |e| {
            words.clearRetainingCapacity();
            try appendString(gpa, &words, e);
            try encode(gpa, &out, .OpExtension, words.items);
        }
        try out.appendSlice(gpa, m.sections[@intFromEnum(Section.extension)].items);
        try out.appendSlice(gpa, m.sections[@intFromEnum(Section.ext_inst_import)].items);
        if (m.sections[@intFromEnum(Section.memory_model)].items.len == 0)
            try encode(gpa, &out, .OpMemoryModel, &.{ @intFromEnum(spec.AddressingModel.Logical), @intFromEnum(spec.MemoryModel.GLSL450) })
        else
            try out.appendSlice(gpa, m.sections[@intFromEnum(Section.memory_model)].items);
        for (m.entries.items) |e| {
            words.clearRetainingCapacity();
            try words.appendSlice(gpa, &.{ @intFromEnum(e.model), e.func.word() });
            try appendString(gpa, &words, e.name);
            for (e.interface) |v| try words.append(gpa, v.word());
            if (m.opts.version.minor() >= 4) for (m.globals.items) |g| {
                if (std.mem.indexOfScalar(Id, e.interface, g[0]) == null) try words.append(gpa, g[0].word());
            };
            try encode(gpa, &out, .OpEntryPoint, words.items);
        }
        try out.appendSlice(gpa, m.sections[@intFromEnum(Section.entry_point)].items);
        inline for (.{ Section.execution_mode, Section.debug_string, Section.debug_name, Section.annotation, Section.global }) |s|
            try out.appendSlice(gpa, m.sections[@intFromEnum(s)].items);
        for (m.functions.items) |f| try f.emit(&out);
        try out.appendSlice(gpa, m.sections[@intFromEnum(Section.function)].items);
        const header = [5]u32{ spec.magic, @intFromEnum(m.opts.version), 0, m.next_id, 0 };
        try out.insertSlice(gpa, 0, &header);
        return out.toOwnedSlice(gpa);
    }
};

/// A function under construction. `OpVariable`s made with `local` go to
/// the start of the first block, as SPIR-V requires.
pub const Function = struct {
    m: *Module,
    id: Id,
    ret: Id,
    ty: Id,
    control: spec.FunctionControl = .{},
    params: std.ArrayList(struct { Id, Id }) = .empty,
    vars: std.ArrayList(u32) = .empty,
    body: std.ArrayList(u32) = .empty,
    /// Where the first block's `OpLabel` ends in `body`.
    first_block_end: ?usize = null,

    fn deinit(f: *Function) void {
        const gpa = f.m.gpa;
        f.params.deinit(gpa);
        f.vars.deinit(gpa);
        f.body.deinit(gpa);
        gpa.destroy(f);
    }

    /// The id of parameter `i`.
    pub fn param(f: *const Function, i: usize) Id {
        return f.params.items[i][1];
    }

    /// Emits `OpLabel %l` (start of a block). Pass an id from `m.newId()`
    /// when branches refer to the block before it starts.
    pub fn label(f: *Function, l: Id) Error!void {
        try encode(f.m.gpa, &f.body, .OpLabel, &.{l.word()});
        if (f.first_block_end == null) f.first_block_end = f.body.items.len;
    }

    /// Emits an instruction without a result.
    pub fn op(f: *Function, opcode: Opcode, operands: []const u32) Error!void {
        try encode(f.m.gpa, &f.body, opcode, operands);
    }

    /// Emits `%r = opcode %ty operands` and returns `%r`.
    pub fn result(f: *Function, opcode: Opcode, ty: Id, operands: []const u32) Error!Id {
        const gpa = f.m.gpa;
        const r = f.m.newId();
        const n: u32 = @intCast(3 + operands.len);
        try f.body.append(gpa, n << 16 | @intFromEnum(opcode));
        try f.body.appendSlice(gpa, &.{ ty.word(), r.word() });
        try f.body.appendSlice(gpa, operands);
        return r;
    }

    /// A Function-storage variable of pointer type `ptr_ty`.
    pub fn local(f: *Function, ptr_ty: Id) Error!Id {
        const r = f.m.newId();
        try encode(f.m.gpa, &f.vars, .OpVariable, &.{ ptr_ty.word(), r.word(), @intFromEnum(StorageClass.Function) });
        return r;
    }

    /// `OpExtInst %ty %glsl <inst> args`.
    pub fn glsl(f: *Function, ty: Id, inst: spec.GlslStd450, args: []const Id) Error!Id {
        var words: [16]u32 = undefined;
        words[0] = (try f.m.glslStd450()).word();
        words[1] = @intFromEnum(inst);
        for (args, 2..) |a, i| words[i] = a.word();
        return f.result(.OpExtInst, ty, words[0 .. args.len + 2]);
    }

    fn emit(f: *Function, out: *std.ArrayList(u32)) Error!void {
        const gpa = f.m.gpa;
        try encode(gpa, out, .OpFunction, &.{ f.ret.word(), f.id.word(), @bitCast(f.control), f.ty.word() });
        for (f.params.items) |p| try encode(gpa, out, .OpFunctionParameter, &.{ p[0].word(), p[1].word() });
        const split = f.first_block_end orelse f.body.items.len;
        try out.appendSlice(gpa, f.body.items[0..split]);
        try out.appendSlice(gpa, f.vars.items);
        try out.appendSlice(gpa, f.body.items[split..]);
        try encode(gpa, out, .OpFunctionEnd, &.{});
    }
};

/// `(word_count << 16) | opcode`, then the operands.
pub fn encode(gpa: std.mem.Allocator, list: *std.ArrayList(u32), op: Opcode, operands: []const u32) Error!void {
    const n: u32 = @intCast(operands.len + 1);
    std.debug.assert(n <= 0xffff);
    try list.append(gpa, n << 16 | @intFromEnum(op));
    try list.appendSlice(gpa, operands);
}

/// UTF-8, NUL-terminated, zero-padded to a whole word.
pub fn appendString(gpa: std.mem.Allocator, list: *std.ArrayList(u32), s: []const u8) Error!void {
    const n = s.len / 4 + 1;
    const start = list.items.len;
    try list.appendNTimes(gpa, 0, n);
    const bytes = std.mem.sliceAsBytes(list.items[start..]);
    @memcpy(bytes[0..s.len], s);
    // Words are little-endian in memory on every supported host; make it
    // explicit for big-endian ones.
    if (@import("builtin").cpu.arch.endian() == .big) {
        for (list.items[start..]) |*w| w.* = @byteSwap(w.*);
    }
}

/// Encodes a decoration or execution-mode parameter.
fn encodeArg(gpa: std.mem.Allocator, list: *std.ArrayList(u32), value: anytype) Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .int, .comptime_int => try list.append(gpa, @intCast(value)),
        .float => try list.append(gpa, @bitCast(@as(f32, value))),
        .@"enum" => try list.append(gpa, @intFromEnum(value)),
        .optional => if (value) |v| try encodeArg(gpa, list, v),
        .pointer => |p| if (p.child == u8) try appendString(gpa, list, value) else for (value) |v| try encodeArg(gpa, list, v),
        .@"struct" => |s| if (s.layout == .@"packed") try list.append(gpa, @bitCast(value)) else inline for (s.fields) |fld| try encodeArg(gpa, list, @field(value, fld.name)),
        else => @compileError("unsupported operand type " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------- tests

/// The minimal fragment shader: writes a constant colour to location 0.
pub fn minimalFrag(gpa: std.mem.Allocator) Error![]u32 {
    var m: Module = .init(gpa, .{});
    defer m.deinit();
    const void_t = try m.typeVoid();
    const f32_t = try m.typeFloat(32);
    const vec4 = try m.typeVector(f32_t, 4);
    const out_ptr = try m.typePointer(.Output, vec4);
    const out = try m.variable(out_ptr, .Output);
    try m.decorate(out, .{ .Location = 0 });
    try m.name(out, "out_color");
    const one = try m.constant(f32_t, 1.0);
    const half = try m.constant(f32_t, 0.5);
    const color = try m.constantComposite(vec4, &.{ half, half, one, one });
    const f = try m.function(void_t, &.{});
    try m.name(f.id, "main");
    try f.label(m.newId());
    try f.op(.OpStore, &.{ out.word(), color.word() });
    try f.op(.OpReturn, &.{});
    try m.entryPoint(.Fragment, f, "main", &.{out});
    try m.executionMode(f, .OriginUpperLeft);
    return m.finish();
}

fn opsOf(gpa: std.mem.Allocator, words: []const u32) ![]Opcode {
    var list: std.ArrayList(Opcode) = .empty;
    var i: usize = 5;
    while (i < words.len) {
        try list.append(gpa, @enumFromInt(@as(u16, @truncate(words[i]))));
        i += words[i] >> 16;
    }
    return list.toOwnedSlice(gpa);
}

test "builder: header and section order" {
    const gpa = std.testing.allocator;
    const words = try minimalFrag(gpa);
    defer gpa.free(words);
    try std.testing.expectEqual(spec.magic, words[0]);
    try std.testing.expectEqual(@as(u32, 0x0001_0300), words[1]);
    try std.testing.expectEqual(@as(u32, 0), words[2]);
    try std.testing.expectEqual(@as(u32, 0), words[4]);
    const ops = try opsOf(gpa, words);
    defer gpa.free(ops);
    const want = [_]Opcode{
        .OpCapability, .OpMemoryModel, .OpEntryPoint,        .OpExecutionMode, .OpName,        .OpName,
        .OpDecorate,   .OpTypeVoid,    .OpTypeFloat,         .OpTypeVector,    .OpTypePointer, .OpVariable,
        .OpConstant,   .OpConstant,    .OpConstantComposite, .OpTypeFunction,  .OpFunction,    .OpLabel,
        .OpStore,      .OpReturn,      .OpFunctionEnd,
    };
    try std.testing.expectEqualSlices(Opcode, &want, ops);
    // Every id is below the bound.
    try std.testing.expect(words[3] > 1);
}

test "builder: type dedup" {
    var m: Module = .init(std.testing.allocator, .{});
    defer m.deinit();
    const a = try m.typeFloat(32);
    try std.testing.expectEqual(a, try m.typeFloat(32));
    try std.testing.expect(a != try m.typeFloat(64));
    const v = try m.typeVector(a, 4);
    try std.testing.expectEqual(v, try m.typeVector(a, 4));
    try std.testing.expectEqual(try m.constant(a, 1.0), try m.constant(a, 1.0));
    try std.testing.expect(try m.constant(a, 1.0) != try m.constant(a, 2.0));
    // Structs stay distinct: each may carry its own decorations.
    const s1 = try m.typeStruct(&.{ a, v });
    const s2 = try m.typeStruct(&.{ a, v });
    try std.testing.expect(s1 != s2);
    try m.memberDecorate(s1, 0, .{ .Offset = 0 });
}

test "builder: string padding" {
    const gpa = std.testing.allocator;
    for (0..9) |len| {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(gpa);
        const s = "abcdefgh"[0..len];
        try appendString(gpa, &list, s);
        try std.testing.expectEqual(len / 4 + 1, list.items.len);
        const bytes = std.mem.sliceAsBytes(list.items);
        try std.testing.expectEqualStrings(s, bytes[0..len]);
        for (bytes[len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "builder: entry point interface 1.3 vs 1.4" {
    const gpa = std.testing.allocator;
    inline for (.{ Version.v1_3, Version.v1_4 }) |ver| {
        var m: Module = .init(gpa, .{ .version = ver });
        defer m.deinit();
        const f32_t = try m.typeFloat(32);
        const in = try m.variable(try m.typePointer(.Input, f32_t), .Input);
        const pc = try m.variable(try m.typePointer(.Private, f32_t), .Private);
        const f = try m.function(try m.typeVoid(), &.{});
        try f.label(m.newId());
        try f.op(.OpReturn, &.{});
        try m.entryPoint(.Fragment, f, "main", &.{in});
        const words = try m.finish();
        defer gpa.free(words);
        // Find OpEntryPoint and count its interface ids.
        var i: usize = 5;
        const n = while (i < words.len) : (i += words[i] >> 16) {
            if (@as(u16, @truncate(words[i])) == @intFromEnum(Opcode.OpEntryPoint)) break (words[i] >> 16) - 1 - 2 - 2;
        } else unreachable;
        try std.testing.expectEqual(@as(u32, if (ver == .v1_3) 1 else 2), n);
        _ = pc;
    }
}

test "builder: minimal fragment shader words golden" {
    const gpa = std.testing.allocator;
    const words = try minimalFrag(gpa);
    defer gpa.free(words);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try hexDump(&out.writer, words);
    try std.testing.expectEqualStrings(@embedFile("testdata/golden/minimal_frag.words"), out.written());
}

/// Four words per line, as in `testdata/golden/*.words`.
pub fn hexDump(w: *std.Io.Writer, words: []const u32) std.Io.Writer.Error!void {
    for (words, 0..) |x, i| {
        try w.print("{x:0>8}", .{x});
        try w.writeByte(if (i % 4 == 3 or i + 1 == words.len) '\n' else ' ');
    }
}

test "builder: decorations with parameters" {
    var m: Module = .init(std.testing.allocator, .{});
    defer m.deinit();
    const f32_t = try m.typeFloat(32);
    const v = try m.variable(try m.typePointer(.Input, f32_t), .Input);
    try m.decorate(v, .{ .BuiltIn = .FragCoord });
    try m.decorate(v, .Flat);
    const s = m.sections[@intFromEnum(Section.annotation)].items;
    try std.testing.expectEqualSlices(u32, &.{
        4 << 16 | 71, v.word(), 11, @intFromEnum(spec.BuiltIn.FragCoord),
        3 << 16 | 71, v.word(), 14,
    }, s[0..7]);
}
