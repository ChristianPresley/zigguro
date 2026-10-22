//! Zig structure from `std.zig.Ast`: folds, outline, scopes, selection
//! ranges and indent depth. The parser is error-tolerant, so structure is
//! produced for broken code too (`ast.errors` are ignored here).
//!
//! Meant to run off the UI thread on a snapshot's text: a full parse of
//! 100k lines takes tens of milliseconds.

const std = @import("std");
const structure = @import("structure.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const ByteRange = structure.ByteRange;
const Builder = structure.Builder;
const Structure = structure.Structure;

/// Files above this size get no tier-2 structure.
pub const max_bytes = 256 << 20;

/// Parses `text` (any bytes; copied with a 0 sentinel) into a Structure
/// tagged with `version`.
pub fn parse(gpa: Allocator, text: []const u8, version: u64) structure.ParseError!Structure {
    if (text.len > max_bytes) return error.TooLarge;
    const src = try gpa.allocSentinel(u8, text.len, 0);
    defer gpa.free(src);
    @memcpy(src, text);
    var tree = try Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);

    var w: Walker = .{ .tree = &tree, .src = src, .b = .init(gpa), .lines = .empty };
    errdefer w.b.deinit();
    defer w.lines.deinit(gpa);
    try w.indexLines(gpa);
    try w.walkAll();
    try w.docCommentFolds();
    try w.b.span(.{ .start = 0, .end = @intCast(src.len) });
    try w.outlineMembers(tree.rootDecls(), null);
    return w.b.finish(version);
}

const Walker = struct {
    tree: *const Ast,
    src: [:0]const u8,
    b: Builder,
    /// Byte offset of each line start.
    lines: std.ArrayList(u32),

    fn indexLines(w: *Walker, gpa: Allocator) Allocator.Error!void {
        try w.lines.append(gpa, 0);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, w.src, i, '\n')) |nl| : (i = nl + 1) try w.lines.append(gpa, @intCast(nl + 1));
    }

    fn lineOf(w: *const Walker, off: u32) u32 {
        var lo: usize = 0;
        var hi: usize = w.lines.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (w.lines.items[mid] <= off) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo - 1);
    }

    /// The end of the line holding `off` (before its newline).
    fn lineEnd(w: *const Walker, off: u32) u32 {
        const l = w.lineOf(off);
        if (l + 1 < w.lines.items.len) {
            const next = w.lines.items[l + 1] - 1;
            return if (next > 0 and w.src[next - 1] == '\r') next - 1 else next;
        }
        return @intCast(w.src.len);
    }

    fn tokStart(w: *const Walker, t: Ast.TokenIndex) u32 {
        return w.tree.tokenStart(t);
    }

    /// The end of token `t`: fixed lexemes by length, the rest by a short
    /// forward scan (cheaper than `tokenSlice`, which re-tokenizes).
    fn tokEnd(w: *const Walker, t: Ast.TokenIndex) u32 {
        const tree = w.tree;
        const start = tree.tokenStart(t);
        const tag = tree.tokenTag(t);
        if (tag.lexeme()) |lx| return start + @as(u32, @intCast(lx.len));
        const src = w.src;
        var i: usize = start;
        switch (tag) {
            .identifier, .builtin, .number_literal => {
                if (src[i] == '@') i += 1;
                if (src[i] == '"') return quotedEnd(src, i);
                while (i < src.len and isTokenByte(src[i], tag == .number_literal)) i += 1;
            },
            .string_literal => return quotedEnd(src, i),
            .char_literal => return quotedEnd(src, i),
            else => {
                // Comments and multiline string lines run to the line end.
                while (i < src.len and src[i] != '\n') i += 1;
                if (i > start and src[i - 1] == '\r') i -= 1;
            },
        }
        return @intCast(i);
    }

    fn isTokenByte(b: u8, number: bool) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or (number and (b == '.' or b == '+' or b == '-'));
    }

    /// The end of a quoted literal starting at `i` (its opening quote).
    fn quotedEnd(src: []const u8, start: usize) u32 {
        const q = src[start];
        var i = start + 1;
        while (i < src.len) : (i += 1) switch (src[i]) {
            '\\' => i += 1,
            '\n' => break,
            else => if (src[i] == q) return @intCast(i + 1),
        };
        return @intCast(@min(i, src.len));
    }

    fn nodeRange(w: *const Walker, n: Node.Index) ByteRange {
        return .{ .start = w.tokStart(w.tree.firstToken(n)), .end = w.tokEnd(w.tree.lastToken(n)) };
    }

    fn header(w: *const Walker, r: ByteRange) ByteRange {
        return .{ .start = r.start, .end = @max(r.start, @min(r.end, w.lineEnd(r.start))) };
    }

    fn walkAll(w: *Walker) Allocator.Error!void {
        const tree = w.tree;
        const n_nodes = tree.nodes.len;
        var i: u32 = 1; // 0 is the root
        while (i < n_nodes) : (i += 1) {
            const n: Node.Index = @enumFromInt(i);
            const tag = tree.nodeTag(n);
            switch (tag) {
                // Single tokens: selection by word covers them.
                .identifier, .number_literal, .string_literal, .char_literal, .enum_literal, .error_value, .unreachable_literal, .anyframe_literal => continue,
                else => {},
            }
            const r = w.nodeRange(n);
            try w.b.span(r);
            switch (tag) {
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    try w.foldRange(r, .block);
                    // A labeled block (`blk: {`) is a scope of its own.
                    const lbrace = tree.nodeMainToken(n);
                    if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon and tree.tokenTag(lbrace - 2) == .identifier) {
                        const lr: ByteRange = .{ .start = w.tokStart(lbrace - 2), .end = r.end };
                        try w.b.scope(.{ .kind = .block, .range = lr, .header = w.header(lr), .name = tree.tokenSlice(lbrace - 2) });
                    }
                },
                .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing, .tagged_union, .tagged_union_trailing, .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing, .error_set_decl => {
                    try w.foldRange(r, .block);
                    const name = w.declName(tree.firstToken(n));
                    try w.b.scope(.{ .kind = .container, .range = r, .header = w.header(r), .name = name });
                },
                .@"switch", .switch_comma => {
                    try w.foldRange(r, .block);
                    try w.b.scope(.{ .kind = .@"switch", .range = r, .header = w.header(r) });
                },
                .array_init, .array_init_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_one, .array_init_one_comma, .struct_init, .struct_init_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_one, .struct_init_one_comma, .call, .call_comma, .builtin_call, .builtin_call_comma => try w.foldRange(r, .block),
                .multiline_string_literal => try w.foldRange(r, .string),
                .fn_decl => {
                    var buf: [1]Node.Index = undefined;
                    const proto = tree.fullFnProto(&buf, n).?;
                    const name = if (proto.name_token) |t| tree.tokenSlice(t) else "";
                    try w.b.scope(.{ .kind = .function, .range = r, .header = w.header(r), .name = name });
                },
                .test_decl => {
                    const name_tok = tree.nodeData(n).opt_token_and_node[0].unwrap();
                    const name = if (name_tok) |t| tree.tokenSlice(t) else "";
                    try w.b.scope(.{ .kind = .test_decl, .range = r, .header = w.header(r), .name = name });
                },
                .if_simple, .@"if" => try w.b.scope(.{ .kind = .@"if", .range = r, .header = w.header(r) }),
                .while_simple, .while_cont, .@"while" => try w.b.scope(.{ .kind = .@"while", .range = r, .header = w.header(r) }),
                .for_simple, .@"for" => try w.b.scope(.{ .kind = .@"for", .range = r, .header = w.header(r) }),
                else => {},
            }
        }
    }

    fn foldRange(w: *Walker, r: ByteRange, kind: structure.FoldKind) Allocator.Error!void {
        try w.b.fold(w.lineOf(r.start), w.lineOf(r.end -| 1), kind);
    }

    /// `Name` in `const Name = struct`, `pub const Name = packed union`.
    fn declName(w: *const Walker, first: Ast.TokenIndex) []const u8 {
        const tree = w.tree;
        if (first >= 2 and tree.tokenTag(first - 1) == .equal and tree.tokenTag(first - 2) == .identifier)
            return tree.tokenSlice(first - 2);
        return "";
    }

    /// Runs of two or more doc-comment lines fold.
    fn docCommentFolds(w: *Walker) Allocator.Error!void {
        const tree = w.tree;
        const tags = tree.tokens.items(.tag);
        var i: u32 = 0;
        while (i < tags.len) : (i += 1) {
            if (tags[i] != .doc_comment and tags[i] != .container_doc_comment) continue;
            const first = i;
            while (i + 1 < tags.len and tags[i + 1] == tags[first]) i += 1;
            try w.b.fold(w.lineOf(w.tokStart(first)), w.lineOf(w.tokStart(i)), .comment);
        }
    }

    /// Outline symbols for container members, recursing into containers.
    fn outlineMembers(w: *Walker, members: []const Node.Index, parent: ?u32) Allocator.Error!void {
        const tree = w.tree;
        var imports_first: ?u32 = null;
        var imports_last: u32 = 0;
        for (members) |m| {
            const r = w.nodeRange(m);
            var is_import = false;
            switch (tree.nodeTag(m)) {
                .fn_decl => {
                    var buf: [1]Node.Index = undefined;
                    const proto = tree.fullFnProto(&buf, m).?;
                    if (proto.name_token) |t| _ = try w.b.symbol(.{
                        .name = tree.tokenSlice(t),
                        .kind = .function,
                        .range = r,
                        .selection = w.tokRange(t),
                        .parent = parent,
                        .is_pub = proto.visib_token != null,
                    });
                },
                .test_decl => {
                    const t = tree.nodeData(m).opt_token_and_node[0].unwrap();
                    _ = try w.b.symbol(.{
                        .name = if (t) |x| tree.tokenSlice(x) else "test",
                        .kind = .test_decl,
                        .range = r,
                        .selection = if (t) |x| w.tokRange(x) else w.tokRange(tree.nodeMainToken(m)),
                        .parent = parent,
                    });
                },
                .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                    const vd = tree.fullVarDecl(m).?;
                    const name_tok = vd.ast.mut_token + 1;
                    const is_const = tree.tokenTag(vd.ast.mut_token) == .keyword_const;
                    var kind: structure.SymbolKind = if (is_const) .constant else .variable;
                    var children: ?[]const Node.Index = null;
                    var buf: [2]Node.Index = undefined;
                    if (vd.ast.init_node.unwrap()) |init| {
                        if (tree.fullContainerDecl(&buf, init)) |cd| {
                            kind = switch (tree.tokenTag(cd.ast.main_token)) {
                                .keyword_enum => .@"enum",
                                .keyword_union => .@"union",
                                .keyword_opaque => .@"opaque",
                                else => .@"struct",
                            };
                            children = cd.ast.members;
                        } else if (tree.nodeTag(init) == .error_set_decl) {
                            kind = .error_set;
                        } else if (tree.nodeTag(init) == .builtin_call_two and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@import")) {
                            is_import = true;
                        }
                    }
                    const idx = try w.b.symbol(.{
                        .name = tree.tokenSlice(name_tok),
                        .kind = kind,
                        .range = r,
                        .selection = w.tokRange(name_tok),
                        .parent = parent,
                        .is_pub = vd.visib_token != null,
                    });
                    if (children) |c| try w.outlineMembers(c, idx);
                },
                .container_field_init, .container_field_align, .container_field => {
                    const f = tree.fullContainerField(m).?;
                    _ = try w.b.symbol(.{
                        .name = tree.tokenSlice(f.ast.main_token),
                        .kind = .field,
                        .range = r,
                        .selection = w.tokRange(f.ast.main_token),
                        .parent = parent,
                    });
                },
                else => {},
            }
            // Consecutive `@import` declarations fold together.
            const line = w.lineOf(r.start);
            if (is_import) {
                if (imports_first == null) imports_first = line;
                imports_last = w.lineOf(r.end -| 1);
            } else if (imports_first) |f| {
                try w.b.fold(f, imports_last, .imports);
                imports_first = null;
            }
        }
        if (imports_first) |f| try w.b.fold(f, imports_last, .imports);
    }

    fn tokRange(w: *const Walker, t: Ast.TokenIndex) ByteRange {
        return .{ .start = w.tokStart(t), .end = w.tokEnd(t) };
    }
};
