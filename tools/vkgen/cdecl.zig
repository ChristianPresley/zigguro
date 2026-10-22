//! C declarators from vk.xml. A `<member>`, `<param>` or `<proto>` is a
//! sequence of text and `<type>`/`<name>`/`<enum>` children; the children are
//! authoritative and the text supplies only `const`, `*`, `[N]` and `:N`.

const std = @import("std");

pub const Error = error{ InvalidDeclarator, OutOfMemory };

/// One piece of a declaration element.
pub const Piece = struct {
    kind: Kind,
    s: []const u8,

    pub const Kind = enum { text, type, name, @"enum" };
};

/// An array dimension.
pub const ArrayDim = union(enum) {
    lit: u32,
    /// An API constant such as `VK_MAX_EXTENSION_NAME_SIZE`.
    constant: []const u8,
};

/// A parsed C type.
pub const CType = struct {
    base: []const u8,
    /// Number of `*`.
    ptr_depth: u8 = 0,
    /// `pointee_const[k]`: the pointee of the k-th `*` (0 = innermost) is
    /// const. `pointee_const[0]` is the base's own `const`.
    pointee_const: [4]bool = @splat(false),
    dims: []const ArrayDim = &.{},
    bitfield: ?u8 = null,

    pub fn isConst(t: CType) bool {
        return t.pointee_const[0];
    }
};

/// The `<name>` text.
pub fn nameOf(ps: []const Piece) ?[]const u8 {
    return firstOf(ps, .name);
}

/// The first piece of kind `k`.
pub fn firstOf(ps: []const Piece, k: Piece.Kind) ?[]const u8 {
    for (ps) |p| if (p.kind == k) return p.s;
    return null;
}

/// Parses a member, param or proto.
pub fn parse(a: std.mem.Allocator, ps: []const Piece) Error!CType {
    const ti = indexOf(ps, .type) orelse return error.InvalidDeclarator;
    const ni = indexOf(ps, .name) orelse ps.len;
    var t: CType = .{ .base = ps[ti].s };
    for (ps[0..ti]) |p| if (p.kind == .text and hasWord(p.s, "const")) {
        t.pointee_const[0] = true;
    };
    for (ps[ti + 1 .. ni]) |p| {
        if (p.kind != .text) return error.InvalidDeclarator;
        var i: usize = 0;
        while (i < p.s.len) {
            const c = p.s[i];
            if (c == '*') {
                if (t.ptr_depth == 3) return error.InvalidDeclarator;
                t.ptr_depth += 1;
                i += 1;
            } else if (std.mem.startsWith(u8, p.s[i..], "const")) {
                t.pointee_const[t.ptr_depth] = true;
                i += 5;
            } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                i += 1;
            } else if (std.mem.startsWith(u8, p.s[i..], "struct")) {
                i += 6;
            } else return error.InvalidDeclarator;
        }
    }
    if (ni < ps.len) {
        var dims: std.ArrayList(ArrayDim) = .empty;
        var pending_open = false;
        for (ps[ni + 1 ..]) |p| switch (p.kind) {
            .@"enum" => {
                if (!pending_open) return error.InvalidDeclarator;
                try dims.append(a, .{ .constant = p.s });
            },
            .text => {
                var i: usize = 0;
                const s = p.s;
                while (i < s.len) {
                    switch (s[i]) {
                        '[' => {
                            i += 1;
                            const close = std.mem.indexOfScalarPos(u8, s, i, ']');
                            if (close) |cl| {
                                const n = std.fmt.parseInt(u32, std.mem.trim(u8, s[i..cl], " "), 10) catch return error.InvalidDeclarator;
                                try dims.append(a, .{ .lit = n });
                                i = cl + 1;
                            } else {
                                if (std.mem.trim(u8, s[i..], " ").len != 0) return error.InvalidDeclarator;
                                pending_open = true;
                                i = s.len;
                            }
                        },
                        ']' => {
                            if (!pending_open) return error.InvalidDeclarator;
                            pending_open = false;
                            i += 1;
                        },
                        ':' => {
                            const n = std.fmt.parseInt(u8, std.mem.trim(u8, s[i + 1 ..], " \t\r\n"), 10) catch return error.InvalidDeclarator;
                            t.bitfield = n;
                            i = s.len;
                        },
                        ' ', '\t', '\r', '\n' => i += 1,
                        else => return error.InvalidDeclarator,
                    }
                }
            },
            else => return error.InvalidDeclarator,
        };
        if (pending_open) return error.InvalidDeclarator;
        t.dims = dims.items;
    }
    return t;
}

/// A basetype's typedef target, or null for an opaque declaration
/// (`struct ANativeWindow;`, Objective-C types, `IOSurfaceRef`).
pub fn basetype(ps: []const Piece) ?CType {
    const ti = indexOf(ps, .type) orelse return null;
    const ni = indexOf(ps, .name) orelse return null;
    if (ni < ti) return null;
    var t: CType = .{ .base = ps[ti].s };
    for (ps[ti + 1 .. ni]) |p| {
        if (p.kind == .text) t.ptr_depth += @intCast(std.mem.countScalar(u8, p.s, '*'));
    }
    return t;
}

/// A parsed legacy-form funcpointer typedef.
pub const FuncPointer = struct {
    ret: CType,
    params: []const struct { name: []const u8, ty: CType },
};

/// Parses `typedef R (VKAPI_PTR *<name>PFN_x</name>)(<type>T</type>* a, ...);`.
pub fn funcpointer(a: std.mem.Allocator, ps: []const Piece) Error!FuncPointer {
    const ni = indexOf(ps, .name) orelse return error.InvalidDeclarator;
    // Return type: the text and types before "(VKAPI_PTR".
    var ret: CType = .{ .base = "" };
    for (ps[0..ni]) |p| {
        var s = p.s;
        if (std.mem.indexOf(u8, s, "(VKAPI_PTR")) |k| s = s[0..k];
        if (p.kind == .type) {
            ret.base = s;
            continue;
        }
        var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
        while (it.next()) |w| {
            var word = w;
            while (word.len > 0 and word[word.len - 1] == '*') : (word = word[0 .. word.len - 1]) ret.ptr_depth += 1;
            if (word.len == 0 or std.mem.eql(u8, word, "typedef")) continue;
            if (std.mem.eql(u8, word, "const")) {
                ret.pointee_const[0] = true;
                continue;
            }
            ret.base = word;
        }
        if (std.mem.indexOf(u8, p.s, "(VKAPI_PTR") != null) break;
    }
    if (ret.base.len == 0) return error.InvalidDeclarator;

    // Parameters: tokens after the name.
    const Tok = struct { kind: enum { word, type, punct }, s: []const u8 };
    var toks: std.ArrayList(Tok) = .empty;
    for (ps[ni + 1 ..]) |p| {
        if (p.kind == .type) {
            try toks.append(a, .{ .kind = .type, .s = p.s });
            continue;
        }
        var i: usize = 0;
        const s = p.s;
        while (i < s.len) {
            const c = s[i];
            if (std.mem.indexOfScalar(u8, "(),;*", c) != null) {
                try toks.append(a, .{ .kind = .punct, .s = s[i .. i + 1] });
                i += 1;
            } else if (std.ascii.isWhitespace(c)) {
                i += 1;
            } else {
                const st = i;
                while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
                if (i == st) return error.InvalidDeclarator;
                try toks.append(a, .{ .kind = .word, .s = s[st..i] });
            }
        }
    }
    // Expect ")" "(" params ")" ";"
    const items = toks.items;
    if (items.len < 4 or !std.mem.eql(u8, items[0].s, ")") or !std.mem.eql(u8, items[1].s, "(")) return error.InvalidDeclarator;
    var params: std.ArrayList(@typeInfo(@FieldType(FuncPointer, "params")).pointer.child) = .empty;
    var i: usize = 2;
    if (items[i].kind == .word and std.mem.eql(u8, items[i].s, "void") and std.mem.eql(u8, items[i + 1].s, ")")) {
        return .{ .ret = ret, .params = params.items };
    }
    while (true) {
        var ty: CType = .{ .base = "" };
        var name: []const u8 = "";
        while (i < items.len) : (i += 1) {
            const t = items[i];
            if (t.kind == .punct and (t.s[0] == ',' or t.s[0] == ')')) break;
            switch (t.kind) {
                .type => ty.base = t.s,
                .punct => if (t.s[0] == '*') {
                    if (ty.ptr_depth == 3) return error.InvalidDeclarator;
                    ty.ptr_depth += 1;
                } else return error.InvalidDeclarator,
                .word => if (std.mem.eql(u8, t.s, "const")) {
                    ty.pointee_const[ty.ptr_depth] = true;
                } else {
                    name = t.s;
                },
            }
        }
        if (i >= items.len or ty.base.len == 0 or name.len == 0) return error.InvalidDeclarator;
        try params.append(a, .{ .name = name, .ty = ty });
        if (items[i].s[0] == ')') break;
        i += 1;
    }
    return .{ .ret = ret, .params = params.items };
}

fn indexOf(ps: []const Piece, k: Piece.Kind) ?usize {
    for (ps, 0..) |p, i| if (p.kind == k) return i;
    return null;
}

fn hasWord(s: []const u8, w: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n*");
    while (it.next()) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

fn pc(kind: Piece.Kind, s: []const u8) Piece {
    return .{ .kind = kind, .s = s };
}

test "cdecl: pointer/const/array/bitfield forms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = std.testing;

    // const char* const* ppEnabledExtensionNames
    var t = try parse(a, &.{ pc(.text, "const "), pc(.type, "char"), pc(.text, "* const*      "), pc(.name, "ppEnabledExtensionNames") });
    try T.expectEqualStrings("char", t.base);
    try T.expectEqual(@as(u8, 2), t.ptr_depth);
    try T.expect(t.pointee_const[0] and t.pointee_const[1]);

    // void* pUserData
    t = try parse(a, &.{ pc(.type, "void"), pc(.text, "* "), pc(.name, "pUserData") });
    try T.expectEqual(@as(u8, 1), t.ptr_depth);
    try T.expect(!t.pointee_const[0]);

    // float blendConstants[4]
    t = try parse(a, &.{ pc(.type, "float"), pc(.text, " "), pc(.name, "blendConstants"), pc(.text, "[4]") });
    try T.expectEqual(@as(u32, 4), t.dims[0].lit);

    // char deviceName[<enum>VK_MAX_PHYSICAL_DEVICE_NAME_SIZE</enum>]
    t = try parse(a, &.{ pc(.type, "char"), pc(.text, " "), pc(.name, "deviceName"), pc(.text, "["), pc(.@"enum", "VK_MAX_PHYSICAL_DEVICE_NAME_SIZE"), pc(.text, "]") });
    try T.expectEqualStrings("VK_MAX_PHYSICAL_DEVICE_NAME_SIZE", t.dims[0].constant);

    // float matrix[3][4]
    t = try parse(a, &.{ pc(.type, "float"), pc(.text, " "), pc(.name, "matrix"), pc(.text, "[3][4]") });
    try T.expectEqual(@as(usize, 2), t.dims.len);
    try T.expectEqual(@as(u32, 3), t.dims[0].lit);
    try T.expectEqual(@as(u32, 4), t.dims[1].lit);

    // uint32_t instanceCustomIndex:24
    t = try parse(a, &.{ pc(.type, "uint32_t"), pc(.text, " "), pc(.name, "instanceCustomIndex"), pc(.text, ":24") });
    try T.expectEqual(@as(?u8, 24), t.bitfield);

    // struct VkBaseOutStructure* pNext
    t = try parse(a, &.{ pc(.text, "struct "), pc(.type, "VkBaseOutStructure"), pc(.text, "* "), pc(.name, "pNext") });
    try T.expectEqualStrings("VkBaseOutStructure", t.base);
    try T.expectEqual(@as(u8, 1), t.ptr_depth);

    // const struct VkBaseInStructure* pNext
    t = try parse(a, &.{ pc(.text, "const struct "), pc(.type, "VkBaseInStructure"), pc(.text, "* "), pc(.name, "pNext") });
    try T.expect(t.isConst());

    // VkResult vkCreateInstance (proto)
    t = try parse(a, &.{ pc(.type, "VkResult"), pc(.text, " "), pc(.name, "vkCreateInstance") });
    try T.expectEqual(@as(u8, 0), t.ptr_depth);

    // void** ppData
    t = try parse(a, &.{ pc(.type, "void"), pc(.text, "** "), pc(.name, "ppData") });
    try T.expectEqual(@as(u8, 2), t.ptr_depth);

    // const uint32_t* pCode
    t = try parse(a, &.{ pc(.text, "const "), pc(.type, "uint32_t"), pc(.text, "* "), pc(.name, "pCode") });
    try T.expect(t.isConst() and t.ptr_depth == 1);

    // Errors.
    try T.expectError(error.InvalidDeclarator, parse(a, &.{pc(.name, "x")}));
    try T.expectError(error.InvalidDeclarator, parse(a, &.{ pc(.type, "int"), pc(.text, " & "), pc(.name, "x") }));
    try T.expectError(error.InvalidDeclarator, parse(a, &.{ pc(.type, "int"), pc(.text, " "), pc(.name, "x"), pc(.text, "[") }));
    try T.expectError(error.InvalidDeclarator, parse(a, &.{ pc(.type, "int"), pc(.text, " "), pc(.name, "x"), pc(.text, "[q]") }));
}

test "cdecl: funcpointer legacy form" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fp = try funcpointer(a, &.{
        pc(.text, "typedef void* (VKAPI_PTR *"),
        pc(.name, "PFN_vkReallocationFunction"),
        pc(.text, ")(\n    "),
        pc(.type, "void"),
        pc(.text, "*   pUserData,\n    const "),
        pc(.type, "VkFoo"),
        pc(.text, "* pFoo,\n    "),
        pc(.type, "size_t"),
        pc(.text, "  size);"),
    });
    try std.testing.expectEqualStrings("void", fp.ret.base);
    try std.testing.expectEqual(@as(u8, 1), fp.ret.ptr_depth);
    try std.testing.expectEqual(@as(usize, 3), fp.params.len);
    try std.testing.expectEqualStrings("pFoo", fp.params[1].name);
    try std.testing.expect(fp.params[1].ty.isConst());
    try std.testing.expectEqualStrings("size_t", fp.params[2].ty.base);

    const v = try funcpointer(a, &.{ pc(.text, "typedef void (VKAPI_PTR *"), pc(.name, "PFN_vkVoidFunction"), pc(.text, ")(void);") });
    try std.testing.expectEqual(@as(usize, 0), v.params.len);
}
