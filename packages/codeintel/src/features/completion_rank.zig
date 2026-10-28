//! Completion items and their ranking (E07.F03.S01.T02): `decode` turns
//! a `textDocument/completion` result into `Item`s with the list's
//! `itemDefaults` applied (edit range, commit characters, insert format
//! and mode, data); `Ranker` filters and sorts them for a pattern.
//!
//! Ranking: with an empty pattern, `preselect` items first; then the
//! fuzzy score (zg_lsp's scorer on `filterText`, else the label; an exact
//! match gets a small bonus); deprecated items after the others; then
//! recently accepted labels (`Recency`, 64 per language); then
//! `sortText` (else the label) ignoring case; then the label.
//!
//! Refiltering is incremental: a pattern that extends the previous one
//! scores only the previous survivors (a subsequence of the longer
//! pattern is one of the shorter); any other pattern scores every item.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_lsp = @import("zg_lsp");

pub const protocol = zg_lsp.protocol;
const fuzzy = zg_lsp.fuzzy;

pub const Kind = protocol.CompletionItemKind;
/// Most pattern characters `Ranker.matches` reports.
pub const max_pattern = fuzzy.max_pattern;

/// An item's documentation.
pub const Doc = union(enum) {
    plain: []const u8,
    markdown: []const u8,
};

/// What accepting an item writes. Ranges are the server's positions in
/// the document as it was requested.
pub const Edit = union(enum) {
    /// Replaces the word before the cursor (the filtered text).
    insert_text: []const u8,
    text_edit: struct { range: protocol.Range, new_text: []const u8 },
    insert_replace: struct { insert: protocol.Range, replace: protocol.Range, new_text: []const u8 },

    pub fn newText(e: Edit) []const u8 {
        return switch (e) {
            .insert_text => |t| t,
            .text_edit => |t| t.new_text,
            .insert_replace => |t| t.new_text,
        };
    }
};

pub const InsertFormat = enum { plain, snippet };
pub const InsertMode = enum { as_is, adjust_indentation };

pub const Item = struct {
    label: []const u8,
    label_detail: ?[]const u8 = null,
    label_desc: ?[]const u8 = null,
    kind: ?protocol.CompletionItemKind = null,
    deprecated: bool = false,
    detail: ?[]const u8 = null,
    doc: ?Doc = null,
    sort_text: []const u8,
    filter_text: []const u8,
    /// The first bytes of `sort_text` in lower case, for sorting.
    sort_key: u64 = 0,
    preselect: bool = false,
    edit: Edit,
    insert_format: InsertFormat = .plain,
    insert_mode: InsertMode = .as_is,
    commit_chars: []const []const u8 = &.{},
    additional: []const protocol.TextEdit = &.{},
    command: ?protocol.Command = null,
    data: ?protocol.LSPAny = null,
    /// The server's index in the request round.
    server: u8 = 0,
    /// The server's item, for `completionItem/resolve`.
    raw: ?*const protocol.CompletionItem = null,
    resolved: bool = false,

    /// Whether `c` (one character, UTF-8) commits this item.
    pub fn commits(it: *const Item, c: []const u8) bool {
        for (it.commit_chars) |cc| if (std.mem.eql(u8, cc, c)) return true;
        return false;
    }
};

/// The first 8 bytes of `s` in lower case, big-endian (ordered like the
/// strings, ties broken by comparing them).
pub fn sortKey(s: []const u8) u64 {
    var b: [8]u8 = @splat(0);
    for (s[0..@min(8, s.len)], 0..) |c, i| b[i] = std.ascii.toLower(c);
    return std.mem.readInt(u64, &b, .big);
}

pub fn docOf(d: protocol.CompletionItemDocumentation) Doc {
    return switch (d) {
        .string => |s| .{ .plain = s },
        .markup_content => |m| if (m.kind == .Markdown) .{ .markdown = m.value } else .{ .plain = m.value },
    };
}

/// Appends the items of `result` (from server `server`) to `out`, with
/// the list's defaults applied; the items borrow from `result`. Returns
/// whether the list is incomplete.
pub fn decode(gpa: Allocator, result: ?protocol.TextDocumentCompletionResult, server: u8, all_commit: []const []const u8, out: *std.ArrayList(Item)) Allocator.Error!bool {
    const r = result orelse return false;
    const list: []const protocol.CompletionItem, const defaults: ?protocol.CompletionItemDefaults, const incomplete = switch (r) {
        .completion_item_array => |a| .{ a, null, false },
        .completion_list => |l| .{ l.items, l.itemDefaults, l.isIncomplete },
    };
    try out.ensureUnusedCapacity(gpa, list.len);
    const d = defaults orelse protocol.CompletionItemDefaults{};
    for (list) |*ci| out.appendAssumeCapacity(itemOf(ci, d, server, all_commit));
    return incomplete;
}

fn itemOf(ci: *const protocol.CompletionItem, d: protocol.CompletionItemDefaults, server: u8, all_commit: []const []const u8) Item {
    const fmt = ci.insertTextFormat orelse d.insertTextFormat orelse .PlainText;
    const mode = ci.insertTextMode orelse d.insertTextMode orelse .asIs;
    var deprecated = ci.deprecated orelse false;
    if (ci.tags) |tags| for (tags) |t| {
        if (t == .Deprecated) deprecated = true;
    };
    const edit: Edit = if (ci.textEdit) |te| switch (te) {
        .text_edit => |t| .{ .text_edit = .{ .range = t.range, .new_text = t.newText } },
        .insert_replace_edit => |t| .{ .insert_replace = .{ .insert = t.insert, .replace = t.replace, .new_text = t.newText } },
    } else if (d.editRange) |er| blk: {
        const text = ci.textEditText orelse ci.insertText orelse ci.label;
        break :blk switch (er) {
            .range => |rg| .{ .text_edit = .{ .range = rg, .new_text = text } },
            .edit_range_with_insert_replace => |ir| .{ .insert_replace = .{ .insert = ir.insert, .replace = ir.replace, .new_text = text } },
        };
    } else .{ .insert_text = ci.insertText orelse ci.label };
    const label_detail, const label_desc = if (ci.labelDetails) |ld| .{ ld.detail, ld.description } else .{ null, null };
    const sort_text = nonEmpty(ci.sortText) orelse ci.label;
    return .{
        .label = ci.label,
        .label_detail = label_detail,
        .label_desc = label_desc,
        .kind = ci.kind,
        .deprecated = deprecated,
        .detail = ci.detail,
        .doc = if (ci.documentation) |doc| docOf(doc) else null,
        .sort_text = sort_text,
        .sort_key = sortKey(sort_text),
        .filter_text = nonEmpty(ci.filterText) orelse ci.label,
        .preselect = ci.preselect orelse false,
        .edit = edit,
        .insert_format = if (fmt == .Snippet) .snippet else .plain,
        .insert_mode = if (mode == .adjustIndentation) .adjust_indentation else .as_is,
        .commit_chars = ci.commitCharacters orelse d.commitCharacters orelse all_commit,
        .additional = ci.additionalTextEdits orelse &.{},
        .command = ci.command,
        .data = ci.data orelse d.data,
        .server = server,
        .raw = ci,
    };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const x = s orelse return null;
    return if (x.len == 0) null else x;
}

/// Hash of what makes two items the same suggestion (label, kind,
/// inserted text), for merging servers' lists.
pub fn dedupKey(it: *const Item) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(it.label);
    h.update(&.{0});
    h.update(std.mem.asBytes(&(if (it.kind) |k| @intFromEnum(k) else @as(u32, 0))));
    h.update(it.edit.newText());
    return h.final();
}

/// Recently accepted labels, newest last; `max` per language.
pub const Recency = struct {
    pub const max = 64;
    const Entry = struct { lang: u64, label: u64 };

    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(r: *Recency, gpa: Allocator) void {
        r.entries.deinit(gpa);
    }

    fn hash(s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }

    pub fn note(r: *Recency, gpa: Allocator, lang: []const u8, label: []const u8) Allocator.Error!void {
        const e: Entry = .{ .lang = hash(lang), .label = hash(label) };
        var n: usize = 0;
        var oldest: ?usize = null;
        for (r.entries.items, 0..) |x, i| {
            if (x.lang != e.lang) continue;
            if (x.label == e.label) {
                _ = r.entries.orderedRemove(i);
                return r.entries.append(gpa, e);
            }
            if (oldest == null) oldest = i;
            n += 1;
        }
        if (n >= max) _ = r.entries.orderedRemove(oldest.?);
        try r.entries.append(gpa, e);
    }

    /// The lookup for one language.
    pub fn view(r: *const Recency, lang: []const u8) View {
        return .{ .r = r, .lang = hash(lang) };
    }

    pub const View = struct {
        r: *const Recency,
        lang: u64,

        pub fn empty(v: View) bool {
            for (v.r.entries.items) |x| if (x.lang == v.lang) return false;
            return true;
        }

        /// 0 for the most recent label, larger for older; `none` when
        /// not recent.
        pub fn rank(v: View, label: []const u8) u8 {
            const h = hash(label);
            var age: u8 = 0;
            var i = v.r.entries.items.len;
            while (i > 0) {
                i -= 1;
                const x = v.r.entries.items[i];
                if (x.lang != v.lang) continue;
                if (x.label == h) return age;
                age += 1;
            }
            return none;
        }

        pub const none: u8 = 255;
    };
};

/// An item that passed the filter.
pub const Ranked = struct {
    /// Orders the list (smaller first): preselect (with an empty
    /// pattern), score, deprecation, recency and the item's place in
    /// `sortText` order, packed in one word.
    key: u64 = 0,
    item: u32,
    score: i32,
    /// `Recency` age (255: not recent).
    recent: u8 = Recency.View.none,

    fn pack(r: *Ranked, it: *const Item, empty: bool, order: u32) void {
        const inv: u64 = @intCast(@as(i32, 1 << 15) - std.math.clamp(r.score, -(1 << 15) + 1, 1 << 15));
        r.key = (@as(u64, @intFromBool(!(empty and it.preselect))) << 63) | (inv << 47) | (@as(u64, @intFromBool(it.deprecated)) << 46) | (@as(u64, r.recent) << 38) | order;
    }
};

/// Bonus for a filter text that equals the pattern (ignoring case).
const exact_bonus = 4;

pub const Ranker = struct {
    gpa: Allocator,
    scratch: *fuzzy.Scratch,
    /// The filtered items, best first.
    ranked: std.ArrayList(Ranked) = .empty,
    pattern: std.ArrayList(u8) = .empty,
    /// Whether `ranked` holds the result of filtering for `pattern`.
    valid: bool = false,
    /// Items scored by the last `refilter` (tests).
    scored: usize = 0,
    /// Each item's place in `sortText` (then label) order; computed
    /// when the items change.
    order: std.ArrayList(u32) = .empty,
    order_valid: bool = false,

    pub fn init(gpa: Allocator) Allocator.Error!Ranker {
        return .{ .gpa = gpa, .scratch = try gpa.create(fuzzy.Scratch) };
    }

    pub fn deinit(r: *Ranker) void {
        r.gpa.destroy(r.scratch);
        r.ranked.deinit(r.gpa);
        r.pattern.deinit(r.gpa);
        r.order.deinit(r.gpa);
    }

    /// The items changed: the next `refilter` scores all of them.
    pub fn reset(r: *Ranker) void {
        r.valid = false;
        r.order_valid = false;
    }

    fn computeOrder(r: *Ranker, items: []const Item) Allocator.Error!void {
        const pairs = try r.gpa.alloc(Pair, items.len);
        defer r.gpa.free(pairs);
        for (pairs, items, 0..) |*p, *it, i| p.* = .{ .key = it.sort_key, .idx = @intCast(i) };
        sortPairs(items, pairs, 0);
        try r.order.resize(r.gpa, items.len);
        for (pairs, 0..) |p, place| r.order.items[p.idx] = @intCast(place);
        r.order_valid = true;
    }

    const Pair = struct { key: u64, idx: u32 };

    /// Sorts by `sortText` ignoring case, 8 bytes at a time (most
    /// comparisons are one integer compare), then by label.
    fn sortPairs(items: []const Item, pairs: []Pair, depth: usize) void {
        std.sort.pdq(Pair, pairs, {}, struct {
            fn lt(_: void, a: Pair, b: Pair) bool {
                return a.key < b.key or (a.key == b.key and a.idx < b.idx);
            }
        }.lt);
        var i: usize = 0;
        while (i < pairs.len) {
            var j = i + 1;
            while (j < pairs.len and pairs[j].key == pairs[i].key) j += 1;
            if (j - i > 1) {
                const run = pairs[i..j];
                const next = (depth + 1) * 8;
                var longer = false;
                for (run) |p| longer = longer or items[p.idx].sort_text.len > next;
                if (longer) {
                    for (run) |*p| p.key = sortKey(items[p.idx].sort_text[@min(next, items[p.idx].sort_text.len)..]);
                    sortPairs(items, run, depth + 1);
                } else std.sort.pdq(Pair, run, items, struct {
                    // Equal sortText: by label, then as listed.
                    fn lt(its: []const Item, a: Pair, b: Pair) bool {
                        return switch (std.mem.order(u8, its[a.idx].label, its[b.idx].label)) {
                            .lt => true,
                            .gt => false,
                            .eq => a.idx < b.idx,
                        };
                    }
                }.lt);
            }
            i = j;
        }
    }

    /// Filters and sorts `items` for `pattern`.
    pub fn refilter(r: *Ranker, items: []const Item, pattern: []const u8, recency: ?Recency.View) Allocator.Error!void {
        if (!r.order_valid or r.order.items.len != items.len) {
            r.valid = false;
            try r.computeOrder(items);
        }
        const extends = r.valid and std.mem.startsWith(u8, pattern, r.pattern.items);
        const f: fuzzy.Fuzzy = .init(pattern);
        const rec: ?Recency.View = if (recency) |v| (if (v.empty()) null else v) else null;
        r.scored = 0;
        if (extends) {
            // Survivors only, in place.
            var keep: usize = 0;
            for (r.ranked.items) |x| {
                r.scored += 1;
                const s = scoreOf(&f, &items[x.item], pattern, r.scratch) orelse continue;
                r.ranked.items[keep] = .{ .item = x.item, .score = s, .recent = if (rec) |v| v.rank(items[x.item].label) else Recency.View.none };
                keep += 1;
            }
            r.ranked.shrinkRetainingCapacity(keep);
        } else {
            r.ranked.clearRetainingCapacity();
            try r.ranked.ensureTotalCapacity(r.gpa, items.len);
            for (items, 0..) |*it, i| {
                r.scored += 1;
                const s = scoreOf(&f, it, pattern, r.scratch) orelse continue;
                r.ranked.appendAssumeCapacity(.{ .item = @intCast(i), .score = s, .recent = if (rec) |v| v.rank(it.label) else Recency.View.none });
            }
        }
        r.pattern.clearRetainingCapacity();
        try r.pattern.appendSlice(r.gpa, pattern);
        r.valid = true;
        for (r.ranked.items) |*x| x.pack(&items[x.item], pattern.len == 0, r.order.items[x.item]);
        std.sort.pdq(Ranked, r.ranked.items, {}, struct {
            fn lt(_: void, a: Ranked, b: Ranked) bool {
                return a.key < b.key;
            }
        }.lt);
    }

    fn scoreOf(f: *const fuzzy.Fuzzy, it: *const Item, pattern: []const u8, scratch: *fuzzy.Scratch) ?i32 {
        const s = f.score(it.filter_text, scratch, null) orelse return null;
        return if (pattern.len > 0 and std.ascii.eqlIgnoreCase(it.filter_text, pattern)) s + exact_bonus else s;
    }

    /// Where `pattern`'s characters matched item `i`'s filter text.
    pub fn matches(r: *const Ranker, it: *const Item, out: *[fuzzy.max_pattern]u16) u8 {
        const f: fuzzy.Fuzzy = .init(r.pattern.items);
        _ = f.score(it.filter_text, r.scratch, out) orelse return 0;
        return f.len;
    }
};

/// Whether byte `c` can be part of a word (identifier characters; bytes
/// of non-ASCII characters count as letters).
pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

pub fn isWordChar(c: u21) bool {
    return c >= 0x80 or isWordByte(@intCast(c));
}
