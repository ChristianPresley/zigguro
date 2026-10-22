//! Batch and incremental Markdown parsing (E04.F06.S01.T01).
//!
//! `parse` reads a whole document. A streaming document (`init`, then
//! `append` per chunk and `finish`) reparses only from the first
//! top-level block that later text could still change: blocks before it
//! keep their indices, text and inlines, and `append` returns a `Delta`
//! naming the top-level blocks it replaced. An incomplete UTF-8 sequence
//! at the end of a chunk waits for the next one.
//!
//! A link reference definition can resolve links in earlier blocks; when
//! a new definition matches a label an earlier block left unresolved, all
//! inlines are parsed again and the delta starts at block 0.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const block_mod = @import("block.zig");
const inline_mod = @import("inline.zig");

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const none = ast.none;

pub const Error = Allocator.Error || error{DocumentTooLarge};

/// Parses `src` (copied) with the full inline parser.
pub fn parse(gpa: Allocator, src: []const u8, opts: ast.Options) Error!Doc {
    return parseWith(gpa, src, opts, inline_mod.inlineParser());
}

/// `parse` with another inline parser (null keeps leaf text whole).
pub fn parseWith(gpa: Allocator, src: []const u8, opts: ast.Options, ip: ?doc_mod.InlineParser) Error!Doc {
    if (src.len > opts.max_bytes) return error.DocumentTooLarge;
    var d = init(gpa, opts);
    errdefer d.deinit();
    d.inline_parser = ip;
    try d.src.appendSlice(gpa, src);
    _ = try reparse(&d, true);
    d.stream.finished = true;
    return d;
}

/// An empty streaming document.
pub fn init(gpa: Allocator, opts: ast.Options) Doc {
    var d = Doc.init(gpa, opts);
    d.inline_parser = inline_mod.inlineParser();
    d.blocks.append(gpa, .{ .kind = .document }) catch {};
    return d;
}

/// Appends a chunk and reparses the unstable tail.
pub fn append(d: *Doc, chunk: []const u8) Error!ast.Delta {
    const st = &d.stream;
    if (d.blocks.items.len == 0) try d.blocks.append(d.gpa, .{ .kind = .document });
    if (d.src.items.len + st.carry_len + chunk.len > d.opts.max_bytes) return error.DocumentTooLarge;
    var data = chunk;
    if (st.carry_len > 0) {
        // Complete the carried sequence first.
        const need = (std.unicode.utf8ByteSequenceLength(st.carry[0]) catch 1) - st.carry_len;
        const take = @min(need, data.len);
        @memcpy(st.carry[st.carry_len..][0..take], data[0..take]);
        st.carry_len += @intCast(take);
        data = data[take..];
        if (take < need) return .{ .first_changed_block = st.stable_blocks, .removed = 0, .added = 0 };
        try d.src.appendSlice(d.gpa, st.carry[0..st.carry_len]);
        st.carry_len = 0;
    }
    const tail = incompleteTail(data);
    try d.src.appendSlice(d.gpa, data[0 .. data.len - tail]);
    @memcpy(st.carry[0..tail], data[data.len - tail ..]);
    st.carry_len = @intCast(tail);
    return reparse(d, false);
}

/// Closes every block (the document is complete).
pub fn finish(d: *Doc) Error!ast.Delta {
    if (d.blocks.items.len == 0) try d.blocks.append(d.gpa, .{ .kind = .document });
    const st = &d.stream;
    if (st.carry_len > 0) {
        // A truncated sequence: keep the bytes; rendering replaces them.
        try d.src.appendSlice(d.gpa, st.carry[0..st.carry_len]);
        st.carry_len = 0;
    }
    const delta = try reparse(d, true);
    st.finished = true;
    return delta;
}

/// Bytes at the end of `s` that start an incomplete UTF-8 sequence.
fn incompleteTail(s: []const u8) usize {
    var k: usize = 0;
    while (k < 3 and k < s.len) : (k += 1) {
        const c = s[s.len - 1 - k];
        if (c & 0xC0 == 0x80) continue;
        if (c < 0x80) return 0;
        const n = std.unicode.utf8ByteSequenceLength(c) catch return 0;
        return if (n > k + 1) k + 1 else 0;
    }
    return 0;
}

fn topCount(d: *const Doc) u32 {
    var n: u32 = 0;
    var c = d.blocks.items[0].first_child;
    while (c != none) : (c = d.blocks.items[c].next) n += 1;
    return n;
}

fn nthTop(d: *const Doc, n: u32) u32 {
    var c = d.blocks.items[0].first_child;
    var k: u32 = 0;
    while (c != none and k < n) : (c = d.blocks.items[c].next) k += 1;
    return c;
}

fn reparse(d: *Doc, final: bool) Error!ast.Delta {
    const st = &d.stream;
    const old_top = topCount(d);
    const old_stable = st.stable_blocks;
    const first = nthTop(d, old_stable);
    var from: u32 = 0;
    if (first != none) {
        from = d.blocks.items[first].line_src[0];
        d.truncate(first, st.stable_inlines, st.stable_pool);
    } else if (old_stable > 0) {
        // Every top-level block was stable: resume after the last one.
        from = st.resume_src;
        d.inlines.shrinkRetainingCapacity(st.stable_inlines);
        d.text_pool.shrinkRetainingCapacity(st.stable_pool);
    }
    const first_new: u32 = @intCast(d.blocks.items.len);
    const res = try block_mod.run(d, from, final);
    const new_stable = @max(res.stable, old_stable);

    // A new definition that resolves an earlier unresolved label means
    // every inline is parsed again.
    var retro = false;
    for (d.unresolved.items) |u| if (d.lookupRef(u.label) != null) {
        retro = true;
        break;
    };
    var first_changed = old_stable;
    if (retro) {
        d.inlines.clearRetainingCapacity();
        d.text_pool.clearRetainingCapacity();
        for (d.unresolved.items) |u| d.gpa.free(u.label);
        d.unresolved.clearRetainingCapacity();
        try parseInlinesFrom(d, 0, nthTopIndex(d, new_stable));
        first_changed = 0;
    } else {
        try parseInlinesFrom(d, first_new, nthTopIndex(d, new_stable));
    }
    st.stable_blocks = new_stable;
    st.stable_inlines = @intCast(d.inlines.items.len);
    st.stable_pool = @intCast(d.text_pool.items.len);
    const boundary = nthTopIndex(d, new_stable);
    if (boundary < d.blocks.items.len) try parseInlinesFrom(d, boundary, @intCast(d.blocks.items.len));
    st.resume_src = if (nthTop(d, new_stable) != none) d.blocks.items[nthTop(d, new_stable)].line_src[0] else @intCast(d.src.items.len);
    const new_top = topCount(d);
    return .{ .first_changed_block = first_changed, .removed = old_top - first_changed, .added = new_top - first_changed };
}

/// The block index where top-level block `n` starts (or the array end).
fn nthTopIndex(d: *const Doc, n: u32) u32 {
    const t = nthTop(d, n);
    return if (t == none) @intCast(d.blocks.items.len) else t;
}

fn parseInlinesFrom(d: *Doc, from: u32, to: u32) Error!void {
    var i = from;
    while (i < to) : (i += 1) {
        const b = &d.blocks.items[i];
        if (!b.kind.hasInlines()) continue;
        if (d.inline_parser) |ip| {
            try ip.parseLeaf(ip.ptr, d, i);
        } else {
            const n = try d.addInline(.{ .kind = .text, .text = b.content });
            d.blocks.items[i].first_inline = n;
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
