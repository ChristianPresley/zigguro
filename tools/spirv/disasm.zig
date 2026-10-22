//! The SPIR-V disassembler (E02.F05.S01.T04): `%12 = OpTypeFloat 32`
//! style, ids printed by their OpName when it is unique, enums by name,
//! GLSL.std.450 instructions by name. Deterministic; it is the golden
//! format for every shader (`testdata/golden/shaders/*.spvasm`).

const std = @import("std");
const spec = @import("spec.zig");
const Cursor = @import("validate.zig").Cursor;

const Opcode = spec.Opcode;

pub const Error = std.Io.Writer.Error || error{ Malformed, OutOfMemory };

const Num = union(enum) { int: struct { bits: u8, signed: bool }, float: u8 };

pub fn disassemble(gpa: std.mem.Allocator, w: *std.Io.Writer, words: []const u32) Error!void {
    if (words.len < 5 or words[0] != spec.magic) return error.Malformed;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Pass 1: names, numeric types, the GLSL import.
    var names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var name_count: std.StringHashMapUnmanaged(u32) = .empty;
    var nums: std.AutoHashMapUnmanaged(u32, Num) = .empty;
    var result_type: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var glsl: u32 = 0;
    var i: usize = 5;
    while (i < words.len) {
        const n = words[i] >> 16;
        if (n == 0 or n > words.len - i) return error.Malformed;
        const op: Opcode = @enumFromInt(@as(u16, @truncate(words[i])));
        const ops = words[i + 1 .. i + n];
        switch (op) {
            .OpName => if (ops.len >= 2) {
                const s = try stringAt(ops[1..]);
                try names.put(arena, ops[0], s);
                (try name_count.getOrPutValue(arena, s, 0)).value_ptr.* += 1;
            },
            .OpTypeInt => if (ops.len >= 3) try nums.put(arena, ops[0], .{ .int = .{ .bits = @truncate(ops[1]), .signed = ops[2] != 0 } }),
            .OpTypeFloat => if (ops.len >= 2) try nums.put(arena, ops[0], .{ .float = @truncate(ops[1]) }),
            .OpExtInstImport => if (ops.len >= 2 and std.mem.eql(u8, try stringAt(ops[1..]), "GLSL.std.450")) {
                glsl = ops[0];
            },
            else => {},
        }
        if (spec.operands(op).len >= 2 and spec.operands(op)[0].kind == .IdResultType and ops.len >= 2)
            try result_type.put(arena, ops[1], ops[0]);
        i += n;
    }

    const ctx: Ctx = .{ .names = &names, .name_count = &name_count, .nums = &nums, .result_type = &result_type, .glsl = glsl };
    try w.print("; SPIR-V\n; Version: {d}.{d}\n; Generator: {d}\n; Bound: {d}\n; Schema: {d}\n", .{ words[1] >> 16 & 0xff, words[1] >> 8 & 0xff, words[2], words[3], words[4] });

    // Pass 2: print.
    i = 5;
    while (i < words.len) {
        const n = words[i] >> 16;
        const op: Opcode = @enumFromInt(@as(u16, @truncate(words[i])));
        try ctx.inst(w, op, words[i + 1 .. i + n]);
        i += n;
    }
}

fn stringAt(ws: []const u32) error{Malformed}![]const u8 {
    const bytes = std.mem.sliceAsBytes(ws);
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.Malformed;
    return bytes[0..end];
}

const Ctx = struct {
    names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    name_count: *const std.StringHashMapUnmanaged(u32),
    nums: *const std.AutoHashMapUnmanaged(u32, Num),
    result_type: *const std.AutoHashMapUnmanaged(u32, u32),
    glsl: u32,

    fn id(c: Ctx, w: *std.Io.Writer, x: u32) Error!void {
        if (c.names.get(x)) |n| {
            if (n.len > 0 and c.name_count.get(n).? == 1) return w.print("%{s}", .{n});
            if (n.len > 0) return w.print("%{s}_{d}", .{ n, x });
        }
        try w.print("%{d}", .{x});
    }

    fn inst(c: Ctx, w: *std.Io.Writer, op: Opcode, ops: []const u32) Error!void {
        const descs = spec.operands(op);
        const opname = std.enums.tagName(Opcode, op) orelse {
            try w.print("{s: >15}Op{d}", .{ "", @intFromEnum(op) });
            for (ops) |x| try w.print(" 0x{x}", .{x});
            return w.writeByte('\n');
        };
        var cur: Cursor = .{ .w = ops };
        var ctx_num: ?Num = null;
        var ext_glsl = false;
        // Result id first, spirv-dis style.
        const ri: ?usize = for (descs, 0..) |d, k| {
            if (d.kind == .IdResult) break k;
        } else null;
        if (ri) |k| {
            if (k >= ops.len) return error.Malformed;
            var buf: [64]u8 = undefined;
            var bw: std.Io.Writer = .fixed(&buf);
            c.id(&bw, ops[k]) catch {};
            try w.print("{s: >14} = ", .{bw.buffered()});
        } else try w.print("{s: >17}", .{""});
        try w.writeAll(opname);
        for (descs) |d| {
            var first = true;
            while (!cur.done() and (first or d.quantifier == .variadic)) : (first = false) {
                if (d.kind == .IdResult) {
                    cur.i += 1;
                    continue;
                }
                if (d.kind == .IdResultType) {
                    const t = cur.w[cur.i];
                    if (op == .OpConstant or op == .OpSpecConstant) ctx_num = c.nums.get(t);
                }
                if (op == .OpExtInst and d.kind == .IdRef and cur.i == 2) ext_glsl = cur.w[cur.i] == c.glsl and c.glsl != 0;
                try w.writeByte(' ');
                try c.operand(w, &cur, d.kind, ctx_num, ext_glsl);
            }
        }
        // Trailing words the grammar does not describe.
        while (!cur.done()) : (cur.i += 1) try w.print(" 0x{x}", .{cur.w[cur.i]});
        try w.writeByte('\n');
    }

    fn operand(c: Ctx, w: *std.Io.Writer, cur: *Cursor, kind: spec.OperandKind, num: ?Num, ext_glsl: bool) Error!void {
        const x = cur.w[cur.i];
        switch (kind) {
            .IdRef, .IdResultType, .IdScope, .IdMemorySemantics, .IdResult => {
                try c.id(w, x);
                cur.i += 1;
            },
            .LiteralString => {
                const s = stringAt(cur.w[cur.i..]) catch {
                    try w.writeAll("<unterminated>");
                    cur.i = cur.w.len;
                    return;
                };
                try w.print("\"{s}\"", .{s});
                cur.i += s.len / 4 + 1;
            },
            .LiteralFloat => {
                try w.print("{d}", .{@as(f32, @bitCast(x))});
                cur.i += 1;
            },
            .LiteralContextDependentNumber => {
                const n = num orelse Num{ .int = .{ .bits = 32, .signed = false } };
                switch (n) {
                    .float => |bits| if (bits == 64 and cur.i + 1 < cur.w.len) {
                        try w.print("{d}", .{@as(f64, @bitCast(@as(u64, cur.w[cur.i + 1]) << 32 | x))});
                        cur.i += 2;
                    } else {
                        if (bits == 16) try w.print("{d}", .{@as(f16, @bitCast(@as(u16, @truncate(x))))}) else try w.print("{d}", .{@as(f32, @bitCast(x))});
                        cur.i += 1;
                    },
                    .int => |t| if (t.bits == 64 and cur.i + 1 < cur.w.len) {
                        const v = @as(u64, cur.w[cur.i + 1]) << 32 | x;
                        if (t.signed) try w.print("{d}", .{@as(i64, @bitCast(v))}) else try w.print("{d}", .{v});
                        cur.i += 2;
                    } else {
                        if (t.signed) try w.print("{d}", .{@as(i32, @bitCast(x))}) else try w.print("{d}", .{x});
                        cur.i += 1;
                    },
                }
            },
            .LiteralExtInstInteger => {
                if (ext_glsl) {
                    if (std.enums.tagName(spec.GlslStd450, @enumFromInt(x))) |n| try w.writeAll(n) else try w.print("{d}", .{x});
                } else try w.print("{d}", .{x});
                cur.i += 1;
            },
            .LiteralSpecConstantOpInteger => {
                if (std.enums.tagName(Opcode, @enumFromInt(@as(u16, @truncate(x))))) |n| try w.writeAll(n) else try w.print("{d}", .{x});
                cur.i += 1;
            },
            .LiteralInteger => {
                try w.print("{d}", .{x});
                cur.i += 1;
            },
            else => switch (kind.category()) {
                .composite => {
                    const b = kind.bases().?;
                    try c.operand(w, cur, b[0], null, false);
                    if (cur.done()) return;
                    try w.writeByte(' ');
                    try c.operand(w, cur, b[1], null, false);
                },
                .value_enum => {
                    if (spec.valueName(kind, x)) |n| try w.writeAll(n) else try w.print("{d}", .{x});
                    cur.i += 1;
                    for (spec.enumParams(kind, x)) |p| {
                        if (cur.done()) break;
                        try w.writeByte(' ');
                        try c.operand(w, cur, p.kind, null, false);
                    }
                },
                .bit_enum => {
                    if (x == 0) try w.writeAll("None");
                    var sep = false;
                    for (0..32) |b| {
                        if (x & (@as(u32, 1) << @intCast(b)) == 0) continue;
                        if (sep) try w.writeByte('|');
                        sep = true;
                        if (spec.bitName(kind, @intCast(b))) |n| try w.writeAll(n) else try w.print("0x{x}", .{@as(u32, 1) << @intCast(b)});
                    }
                    cur.i += 1;
                    for (0..32) |b| {
                        if (x & (@as(u32, 1) << @intCast(b)) == 0) continue;
                        for (spec.enumParams(kind, @as(u32, 1) << @intCast(b))) |p| {
                            if (cur.done()) break;
                            try w.writeByte(' ');
                            try c.operand(w, cur, p.kind, null, false);
                        }
                    }
                },
                else => {
                    try w.print("{d}", .{x});
                    cur.i += 1;
                },
            },
        }
    }
};

// ---------------------------------------------------------------- tests

const builder = @import("builder.zig");

test "disasm: golden minimal_frag.spvasm" {
    const gpa = std.testing.allocator;
    const words = try builder.minimalFrag(gpa);
    defer gpa.free(words);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try disassemble(gpa, &out.writer, words);
    try std.testing.expectEqualStrings(@embedFile("testdata/golden/minimal_frag.spvasm"), out.written());
}

test "disasm: round-trip names" {
    const gpa = std.testing.allocator;
    var m: builder.Module = .init(gpa, .{});
    defer m.deinit();
    const f32_t = try m.typeFloat(32);
    const a = try m.variable(try m.typePointer(.Private, f32_t), .Private);
    const b = try m.variable(try m.typePointer(.Private, f32_t), .Private);
    const c = try m.variable(try m.typePointer(.Private, f32_t), .Private);
    try m.name(a, "unique");
    try m.name(b, "twice");
    try m.name(c, "twice");
    const words = try m.finish();
    defer gpa.free(words);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try disassemble(gpa, &out.writer, words);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "%unique = OpVariable") != null);
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&buf, "%twice_{d} = OpVariable", .{b.word()})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OpName %unique \"unique\"") != null);
}

test "disasm: malformed input is an error" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.Malformed, disassemble(gpa, &out.writer, &.{ 1, 2, 3 }));
    try std.testing.expectError(error.Malformed, disassemble(gpa, &out.writer, &.{ spec.magic, 0x10300, 0, 4, 0, 5 << 16 | 17 }));
}
