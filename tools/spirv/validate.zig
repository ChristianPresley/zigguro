//! The structural SPIR-V validator (E02.F05.S01.T04).
//!
//! Checks module shape, not operand types: the header; instruction
//! lengths against the grammar; logical section order (spec §2.4); id
//! definitions and uses; block and function structure; merge
//! instructions before conditional branches; entry-point interfaces; and
//! explicit layout of Block structs. Semantic validation is left to the
//! Khronos validation layer at runtime. Never reads past the end of
//! `words`.

const std = @import("std");
const spec = @import("spec.zig");

const Opcode = spec.Opcode;

/// The Vulkan environment: the SPIR-V version ceiling (1.5 for Vulkan
/// 1.2, 1.6 for 1.3).
pub const Env = enum {
    vulkan_1_2,
    vulkan_1_3,

    fn maxMinor(e: Env) u8 {
        return switch (e) {
            .vulkan_1_2 => 5,
            .vulkan_1_3 => 6,
        };
    }
};

pub const Issue = struct {
    word_offset: u32,
    opcode: Opcode,
    msg: []const u8,

    pub fn format(self: Issue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.enums.tagName(Opcode, self.opcode)) |n|
            try w.print("{s} at word {d}: {s}", .{ n, self.word_offset, self.msg })
        else
            try w.print("opcode {d} at word {d}: {s}", .{ @intFromEnum(self.opcode), self.word_offset, self.msg });
    }
};

pub fn freeIssues(gpa: std.mem.Allocator, issues: []Issue) void {
    for (issues) |i| gpa.free(i.msg);
    gpa.free(issues);
}

const max_issues = 64;

/// The structural issues in `words`; an empty slice means valid. Free
/// with `freeIssues`.
pub fn validate(gpa: std.mem.Allocator, words: []const u32, env: Env) error{OutOfMemory}![]Issue {
    var v: Validator = .{ .gpa = gpa, .words = words, .env = env };
    defer v.deinit();
    errdefer for (v.issues.items) |i| gpa.free(i.msg);
    try v.run();
    return v.issues.toOwnedSlice(gpa);
}

const Def = struct { offset: u32, op: Opcode };

const Validator = struct {
    gpa: std.mem.Allocator,
    words: []const u32,
    env: Env,
    issues: std.ArrayList(Issue) = .empty,
    defs: std.AutoHashMapUnmanaged(u32, Def) = .empty,
    bound: u32 = 0,
    minor: u8 = 0,

    fn deinit(v: *Validator) void {
        v.issues.deinit(v.gpa);
        v.defs.deinit(v.gpa);
    }

    fn report(v: *Validator, at: usize, op: Opcode, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        if (v.issues.items.len >= max_issues) return;
        const msg = try std.fmt.allocPrint(v.gpa, fmt, args);
        errdefer v.gpa.free(msg);
        try v.issues.append(v.gpa, .{ .word_offset = @intCast(at), .opcode = op, .msg = msg });
    }

    /// One instruction: `words[at..][0..len]`.
    const Inst = struct {
        at: usize,
        op: Opcode,
        w: []const u32,
    };

    /// The instructions, or null after reporting a framing error.
    fn frame(v: *Validator) error{OutOfMemory}!?[]Inst {
        var list: std.ArrayList(Inst) = .empty;
        errdefer list.deinit(v.gpa);
        var i: usize = 5;
        while (i < v.words.len) {
            const n = v.words[i] >> 16;
            const op: Opcode = @enumFromInt(@as(u16, @truncate(v.words[i])));
            if (n == 0) {
                try v.report(i, op, "zero word count", .{});
                list.deinit(v.gpa);
                return null;
            }
            if (n > v.words.len - i) {
                try v.report(i, op, "truncated instruction: {d} words declared, {d} left", .{ n, v.words.len - i });
                list.deinit(v.gpa);
                return null;
            }
            try list.append(v.gpa, .{ .at = i, .op = op, .w = v.words[i + 1 .. i + n] });
            i += n;
        }
        return try list.toOwnedSlice(v.gpa);
    }

    fn run(v: *Validator) error{OutOfMemory}!void {
        if (v.words.len < 5) return v.report(0, .OpNop, "module shorter than its 5-word header", .{});
        if (v.words[0] != spec.magic) return v.report(0, .OpNop, "bad magic 0x{x:0>8}", .{v.words[0]});
        const version = v.words[1];
        v.minor = @truncate(version >> 8);
        if (version >> 16 != 1 or version & 0xff00_00ff != 0 or v.minor > v.env.maxMinor())
            try v.report(1, .OpNop, "version 0x{x:0>8} above the {s} ceiling 1.{d}", .{ version, @tagName(v.env), v.env.maxMinor() });
        v.bound = v.words[3];
        if (v.bound == 0) try v.report(3, .OpNop, "bound is 0", .{});
        if (v.words[4] != 0) try v.report(4, .OpNop, "schema must be 0", .{});

        const insts = (try v.frame()) orelse return;
        defer v.gpa.free(insts);
        for (insts) |in| try v.checkLength(in);
        if (v.issues.items.len > 0) return;
        try v.collectDefs(insts);
        try v.checkUses(insts);
        try v.checkLayout(insts);
        try v.checkInterfaces(insts);
        try v.checkExplicitLayout(insts);
    }

    fn checkLength(v: *Validator, in: Inst) error{OutOfMemory}!void {
        const descs = spec.operands(in.op);
        if (std.enums.tagName(Opcode, in.op) == null) return v.report(in.at, in.op, "unknown opcode {d}", .{@intFromEnum(in.op)});
        var min: usize = 0;
        for (descs) |d| if (d.quantifier == .one) {
            min += if (d.kind.category() == .composite) 2 else 1;
        };
        if (in.w.len < min) return v.report(in.at, in.op, "{d} operand words, the grammar needs at least {d}", .{ in.w.len, min });
        // Strings must be NUL-terminated inside the instruction.
        var cur: Cursor = .{ .w = in.w };
        for (descs) |d| {
            if (cur.done()) break;
            switch (d.quantifier) {
                .one, .optional => if (!cur.skip(d.kind)) return v.report(in.at, in.op, "operand runs past the instruction end", .{}),
                .variadic => while (!cur.done()) {
                    if (!cur.skip(d.kind)) return v.report(in.at, in.op, "operand runs past the instruction end", .{});
                },
            }
        }
    }

    fn resultIndex(op: Opcode) ?usize {
        const descs = spec.operands(op);
        for (descs, 0..) |d, i| if (d.kind == .IdResult) return i;
        return null;
    }

    fn collectDefs(v: *Validator, insts: []const Inst) error{OutOfMemory}!void {
        for (insts) |in| {
            const ri = resultIndex(in.op) orelse continue;
            const r = in.w[ri];
            if (r == 0 or r >= v.bound) {
                try v.report(in.at, in.op, "result id %{d} outside the bound {d}", .{ r, v.bound });
                continue;
            }
            const gop = try v.defs.getOrPut(v.gpa, r);
            if (gop.found_existing) {
                try v.report(in.at, in.op, "id %{d} defined twice (first at word {d})", .{ r, gop.value_ptr.offset });
                continue;
            }
            gop.value_ptr.* = .{ .offset = @intCast(in.at), .op = in.op };
        }
    }

    /// Instructions whose id operands may refer forward.
    fn forwardOk(op: Opcode) bool {
        return switch (op) {
            .OpName, .OpMemberName, .OpDecorate, .OpMemberDecorate, .OpDecorateId, .OpDecorateString, .OpMemberDecorateString, .OpGroupDecorate, .OpGroupMemberDecorate, .OpEntryPoint, .OpExecutionMode, .OpExecutionModeId, .OpBranch, .OpBranchConditional, .OpSwitch, .OpSelectionMerge, .OpLoopMerge, .OpPhi, .OpFunctionCall, .OpTypeForwardPointer => true,
            else => false,
        };
    }

    fn checkUses(v: *Validator, insts: []const Inst) error{OutOfMemory}!void {
        for (insts) |in| {
            var cur: Cursor = .{ .w = in.w };
            const fwd = forwardOk(in.op);
            for (spec.operands(in.op)) |d| {
                var first = true;
                while (!cur.done() and (first or d.quantifier == .variadic)) : (first = false) {
                    var ids: [2]?u32 = .{ null, null };
                    cur.ids(d.kind, &ids);
                    for (ids) |maybe| if (maybe) |x| {
                        const def = v.defs.get(x) orelse {
                            try v.report(in.at, in.op, "undefined id %{d}", .{x});
                            continue;
                        };
                        if (!fwd and def.offset > in.at) try v.report(in.at, in.op, "id %{d} used before its definition at word {d}", .{ x, def.offset });
                    };
                }
            }
        }
    }

    fn section(op: Opcode, in_function: bool) u8 {
        return switch (op) {
            .OpCapability => 0,
            .OpExtension => 1,
            .OpExtInstImport => 2,
            .OpMemoryModel => 3,
            .OpEntryPoint => 4,
            .OpExecutionMode, .OpExecutionModeId => 5,
            .OpString, .OpSourceExtension, .OpSource, .OpSourceContinued => 6,
            .OpName, .OpMemberName => 7,
            .OpModuleProcessed => 8,
            .OpDecorate, .OpMemberDecorate, .OpDecorationGroup, .OpGroupDecorate, .OpGroupMemberDecorate, .OpDecorateId, .OpDecorateString, .OpMemberDecorateString => 9,
            .OpLine, .OpNoLine => 255,
            .OpFunction => 11,
            else => if (in_function) 11 else if (isGlobal(op)) 10 else 11,
        };
    }

    fn isGlobal(op: Opcode) bool {
        const c = spec.class(op);
        return std.mem.eql(u8, c, "Type-Declaration") or std.mem.eql(u8, c, "Constant-Creation") or op == .OpVariable or op == .OpUndef;
    }

    fn isTerminator(op: Opcode) bool {
        return switch (op) {
            .OpBranch, .OpBranchConditional, .OpSwitch, .OpReturn, .OpReturnValue, .OpKill, .OpUnreachable, .OpTerminateInvocation => true,
            else => false,
        };
    }

    fn checkLayout(v: *Validator, insts: []const Inst) error{OutOfMemory}!void {
        var sec: u8 = 0;
        var seen_memory_model = false;
        const State = enum { outside, header, between_blocks, in_block };
        var st: State = .outside;
        var blocks: u32 = 0;
        var only_vars = false;
        var prev: Opcode = .OpNop;
        for (insts) |in| {
            defer prev = in.op;
            const s = section(in.op, st != .outside);
            if (s != 255) {
                if (s < sec) try v.report(in.at, in.op, "out of section order (logical layout, spec 2.4)", .{});
                sec = @max(sec, s);
            }
            if (in.op == .OpMemoryModel) seen_memory_model = true;
            switch (st) {
                .outside => switch (in.op) {
                    .OpFunction => {
                        st = .header;
                        blocks = 0;
                    },
                    .OpFunctionEnd, .OpFunctionParameter, .OpLabel => try v.report(in.at, in.op, "outside a function", .{}),
                    else => if (s == 11) try v.report(in.at, in.op, "instruction outside a function", .{}),
                },
                .header => switch (in.op) {
                    .OpFunctionParameter => {},
                    .OpLabel => {
                        st = .in_block;
                        blocks += 1;
                        only_vars = true;
                    },
                    .OpFunctionEnd => st = .outside,
                    else => try v.report(in.at, in.op, "expected OpFunctionParameter, OpLabel or OpFunctionEnd", .{}),
                },
                .between_blocks => switch (in.op) {
                    .OpLabel => {
                        st = .in_block;
                        blocks += 1;
                        only_vars = false;
                    },
                    .OpFunctionEnd => st = .outside,
                    else => try v.report(in.at, in.op, "instruction outside a block (missing OpLabel)", .{}),
                },
                .in_block => switch (in.op) {
                    .OpLabel => {
                        try v.report(in.at, in.op, "block not terminated before the next OpLabel", .{});
                        blocks += 1;
                        only_vars = false;
                    },
                    .OpFunctionEnd => {
                        try v.report(in.at, in.op, "missing block terminator before OpFunctionEnd", .{});
                        st = .outside;
                    },
                    .OpFunction, .OpFunctionParameter => try v.report(in.at, in.op, "inside a block", .{}),
                    .OpVariable => if (!only_vars or blocks != 1) try v.report(in.at, in.op, "function variable not at the start of the first block", .{}),
                    else => {
                        if (in.op != .OpLine and in.op != .OpNoLine) only_vars = false;
                        if (in.op == .OpBranchConditional or in.op == .OpSwitch) {
                            if (prev != .OpSelectionMerge and prev != .OpLoopMerge) try v.report(in.at, in.op, "missing OpSelectionMerge", .{});
                        }
                        if ((prev == .OpSelectionMerge and in.op != .OpBranchConditional and in.op != .OpSwitch) or
                            (prev == .OpLoopMerge and in.op != .OpBranch and in.op != .OpBranchConditional))
                            try v.report(in.at, in.op, "merge instruction not followed by its branch", .{});
                        if (isTerminator(in.op)) st = .between_blocks;
                    },
                },
            }
        }
        if (st != .outside) try v.report(v.words.len, .OpFunctionEnd, "missing OpFunctionEnd", .{});
        if (!seen_memory_model) try v.report(5, .OpMemoryModel, "missing OpMemoryModel", .{});
    }

    fn checkInterfaces(v: *Validator, insts: []const Inst) error{OutOfMemory}!void {
        for (insts) |in| {
            if (in.op != .OpEntryPoint) continue;
            var cur: Cursor = .{ .w = in.w[2..] };
            _ = cur.skip(.LiteralString);
            while (!cur.done()) {
                const x = cur.w[cur.i];
                cur.i += 1;
                const def = v.defs.get(x) orelse continue;
                if (def.op != .OpVariable) {
                    try v.report(in.at, in.op, "interface id %{d} is not a variable", .{x});
                    continue;
                }
                const var_w = v.words[def.offset + 1 ..][0 .. (v.words[def.offset] >> 16) - 1];
                const sc: spec.StorageClass = @enumFromInt(var_w[2]);
                if (v.minor < 4 and sc != .Input and sc != .Output)
                    try v.report(in.at, in.op, "interface %{d} has storage class {s}; SPIR-V 1.{d} allows only Input/Output", .{ x, @tagName(sc), v.minor });
            }
        }
    }

    /// Block structs reachable from StorageBuffer/Uniform/PushConstant
    /// variables need member Offsets, arrays need ArrayStride.
    fn checkExplicitLayout(v: *Validator, insts: []const Inst) error{OutOfMemory}!void {
        var offsets: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer offsets.deinit(v.gpa);
        var strides: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer strides.deinit(v.gpa);
        var types: std.AutoHashMapUnmanaged(u32, Inst) = .empty;
        defer types.deinit(v.gpa);
        for (insts) |in| switch (in.op) {
            .OpMemberDecorate => if (in.w[2] == @intFromEnum(spec.Decoration.Offset)) try offsets.put(v.gpa, @as(u64, in.w[0]) << 32 | in.w[1], {}),
            .OpDecorate => if (in.w[1] == @intFromEnum(spec.Decoration.ArrayStride)) try strides.put(v.gpa, in.w[0], {}),
            .OpTypeStruct, .OpTypeArray, .OpTypeRuntimeArray, .OpTypePointer => try types.put(v.gpa, in.w[0], in),
            else => {},
        };
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(v.gpa);
        for (insts) |in| {
            if (in.op != .OpVariable) continue;
            const sc: spec.StorageClass = @enumFromInt(in.w[2]);
            if (sc != .StorageBuffer and sc != .Uniform and sc != .PushConstant and sc != .PhysicalStorageBuffer) continue;
            const ptr = types.get(in.w[0]) orelse continue;
            if (ptr.op != .OpTypePointer) continue;
            try v.walkLayout(in, ptr.w[2], &types, &offsets, &strides, &seen);
        }
    }

    fn walkLayout(
        v: *Validator,
        user: Inst,
        ty: u32,
        types: *const std.AutoHashMapUnmanaged(u32, Inst),
        offsets: *const std.AutoHashMapUnmanaged(u64, void),
        strides: *const std.AutoHashMapUnmanaged(u32, void),
        seen: *std.AutoHashMapUnmanaged(u32, void),
    ) error{OutOfMemory}!void {
        if ((try seen.getOrPut(v.gpa, ty)).found_existing) return;
        const t = types.get(ty) orelse return;
        switch (t.op) {
            .OpTypeStruct => for (t.w[1..], 0..) |member, i| {
                if (!offsets.contains(@as(u64, ty) << 32 | i))
                    try v.report(t.at, t.op, "struct %{d} member {d} has no Offset decoration (used by variable %{d})", .{ ty, i, user.w[1] });
                try v.walkLayout(user, member, types, offsets, strides, seen);
            },
            .OpTypeArray, .OpTypeRuntimeArray => {
                if (!strides.contains(ty)) try v.report(t.at, t.op, "array %{d} has no ArrayStride decoration (used by variable %{d})", .{ ty, user.w[1] });
                try v.walkLayout(user, t.w[1], types, offsets, strides, seen);
            },
            else => {},
        }
    }
};

/// Walks the operand words of one instruction by operand kind.
pub const Cursor = struct {
    w: []const u32,
    i: usize = 0,

    pub fn done(c: *const Cursor) bool {
        return c.i >= c.w.len;
    }

    /// Skips one operand of `kind` (not its enum parameters); false when
    /// it would run past the end.
    pub fn skip(c: *Cursor, kind: spec.OperandKind) bool {
        if (kind == .LiteralString) {
            while (c.i < c.w.len) {
                const x = c.w[c.i];
                c.i += 1;
                if (x & 0xff00_0000 == 0 or x & 0x00ff_0000 == 0 or x & 0x0000_ff00 == 0 or x & 0xff == 0) return true;
            }
            return false;
        }
        const n: usize = switch (kind.category()) {
            .composite => 2,
            else => 1,
        };
        if (c.i + n > c.w.len) {
            c.i = c.w.len;
            return false;
        }
        const value = c.w[c.i];
        c.i += n;
        // Enum parameters follow the enumerant.
        switch (kind.category()) {
            .value_enum => for (spec.enumParams(kind, value)) |p| {
                if (c.done()) return p.quantifier != .one;
                if (!c.skip(p.kind)) return false;
            },
            .bit_enum => for (0..32) |b| {
                if (value & (@as(u32, 1) << @intCast(b)) == 0) continue;
                for (spec.enumParams(kind, @as(u32, 1) << @intCast(b))) |p| {
                    if (c.done()) return p.quantifier != .one;
                    if (!c.skip(p.kind)) return false;
                }
            },
            else => {},
        }
        return true;
    }

    /// Consumes one operand of `kind`, writing the ids it references
    /// (not IdResult) to `out`.
    pub fn ids(c: *Cursor, kind: spec.OperandKind, out: *[2]?u32) void {
        out.* = .{ null, null };
        const start = c.i;
        switch (kind) {
            .IdRef, .IdResultType, .IdScope, .IdMemorySemantics => if (c.i < c.w.len) {
                out[0] = c.w[c.i];
            },
            .PairIdRefIdRef => if (c.i + 1 < c.w.len) {
                out.* = .{ c.w[c.i], c.w[c.i + 1] };
            },
            .PairIdRefLiteralInteger => if (c.i < c.w.len) {
                out[0] = c.w[c.i];
            },
            .PairLiteralIntegerIdRef => if (c.i + 1 < c.w.len) {
                out[0] = c.w[c.i + 1];
            },
            else => {},
        }
        if (!c.skip(kind)) c.i = c.w.len;
        // Enum parameters may hold ids (e.g. ImageOperands Lod).
        if (kind.category() == .bit_enum or kind.category() == .value_enum) {
            var j = start + 1;
            const value = c.w[start];
            const end = c.i;
            if (kind.category() == .value_enum) {
                for (spec.enumParams(kind, value)) |p| {
                    if (j >= end) break;
                    if (p.kind == .IdRef and out[0] == null) out[0] = c.w[j] else if (p.kind == .IdRef) out[1] = c.w[j];
                    j += 1;
                }
            } else for (0..32) |b| {
                if (value & (@as(u32, 1) << @intCast(b)) == 0) continue;
                for (spec.enumParams(kind, @as(u32, 1) << @intCast(b))) |p| {
                    if (j >= end) break;
                    if (p.kind == .IdRef) {
                        if (out[0] == null) out[0] = c.w[j] else out[1] = c.w[j];
                    }
                    j += 1;
                }
            }
        }
    }
};

// ---------------------------------------------------------------- tests

const builder = @import("builder.zig");

test "validate: accepts the minimal fragment shader" {
    const gpa = std.testing.allocator;
    const words = try builder.minimalFrag(gpa);
    defer gpa.free(words);
    const issues = try validate(gpa, words, .vulkan_1_2);
    defer freeIssues(gpa, issues);
    for (issues) |i| std.debug.print("{f}\n", .{i});
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "validate: catches each hand-crafted invalid module" {
    const gpa = std.testing.allocator;
    const invalid = @import("testdata/invalid.zig");
    inline for (invalid.cases) |case| {
        const words = try case.build(gpa);
        defer gpa.free(words);
        const issues = try validate(gpa, words, .vulkan_1_2);
        defer freeIssues(gpa, issues);
        var found = false;
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        for (issues) |i| {
            text.clearRetainingCapacity();
            try text.writer.print("{f}", .{i});
            if (std.mem.indexOf(u8, text.written(), case.expect) != null) found = true;
        }
        if (!found) {
            std.debug.print("case {s}: expected \"{s}\", got:\n", .{ case.name, case.expect });
            for (issues) |i| std.debug.print("  {f}\n", .{i});
            return error.TestUnexpectedResult;
        }
    }
}

test "validate: never reads past the end" {
    const gpa = std.testing.allocator;
    const words = try builder.minimalFrag(gpa);
    defer gpa.free(words);
    for (0..words.len) |n| {
        const issues = try validate(gpa, words[0..n], .vulkan_1_3);
        freeIssues(gpa, issues);
    }
}

test "fuzz: validator and disassembler never panic on random words" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var bytes: [1024]u8 align(4) = undefined;
            const n = smith.slice(&bytes) / 4;
            const buf: []u32 = @as([*]u32, @ptrCast(&bytes))[0..n];
            if (n >= 1) buf[0] = spec.magic;
            const issues = try validate(gpa, buf[0..n], .vulkan_1_3);
            freeIssues(gpa, issues);
            var out: std.Io.Writer.Discarding = .init(&.{});
            @import("disasm.zig").disassemble(gpa, &out.writer, buf[0..n]) catch {};
        }
    }.one, .{});
}
