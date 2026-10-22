//! Benchmarks for zg_editor; run with `zig build bench` at the repo root.
//! Inputs are generated (seeded), so runs are reproducible.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const bench = zg_core.bench;

const buffer = zg_editor.model.buffer;
const PieceTree = buffer.piece_tree.PieceTree;
const NodePool = buffer.node_pool.NodePool;
const BufferTable = buffer.buffers.BufferTable;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

/// Budgeted bench names that have no body yet.
pub const pending = [_][]const u8{
    "editor.open.1gb_first_screen",
    "editor.open.10mb_full",
    "editor.find.viewport_1gb",
};

/// A source-like file of `lines` lines (20-120 columns).
fn genLines(gpa: std.mem.Allocator, lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rng: std.Random.DefaultPrng = .init(0x2605);
    const r = rng.random();
    for (0..lines) |_| {
        const n = 20 + r.uintLessThan(usize, 100);
        for (0..n) |_| try out.append(gpa, "abcdefghijklmnopqrstuvwxyz (){};=+"[r.uintLessThan(usize, 34)]);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const Doc = struct {
    pool: NodePool,
    bt: *BufferTable,
    tree: PieceTree,

    fn init(gpa: std.mem.Allocator, text: []const u8) !*Doc {
        const d = try gpa.create(Doc);
        d.pool = .init(gpa);
        d.bt = try BufferTable.create(gpa, try gpa.dupe(u8, text), true);
        d.tree = try PieceTree.fromOriginal(&d.pool, d.bt);
        return d;
    }

    fn deinit(d: *Doc, gpa: std.mem.Allocator) void {
        d.tree.deinit(&d.pool);
        d.pool.deinit();
        d.bt.release();
        gpa.destroy(d);
    }
};

/// One-character inserts at scattered offsets (each a new version).
fn insertChar(d: *Doc, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(1);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const at = r.uintLessThan(u64, d.tree.len());
        const next = d.tree.insert(&d.pool, at, "x") catch unreachable;
        d.tree.deinit(&d.pool);
        d.tree = next;
    }
}

/// Typing: consecutive inserts at one point (the fast path).
fn typeChar(d: *Doc, s: *bench.State) void {
    var at: u64 = d.tree.len() / 2;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const next = d.tree.insert(&d.pool, at, "x") catch unreachable;
        d.tree.deinit(&d.pool);
        d.tree = next;
        at += 1;
    }
}

fn offsetToPoint(d: *Doc, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(2);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        bench.doNotOptimizeAway(d.tree.offsetToPoint(r.uintLessThan(u64, d.tree.len())));
    }
}

fn offsetToUtf16(d: *Doc, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(3);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        bench.doNotOptimizeAway(d.tree.offsetToUtf16(r.uintLessThan(u64, d.tree.len())));
    }
}

/// 1,000 single-character replacements in one pass.
fn replace1k(d: *Doc, s: *bench.State) void {
    var edits: [1000]buffer.piece_tree.Edit = undefined;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const step = d.tree.len() / edits.len;
        for (&edits, 0..) |*e, k| e.* = .{ .range = .{ .start = k * step, .end = k * step }, .text = "y" };
        const next = d.tree.replace(&d.pool, &edits) catch unreachable;
        d.tree.deinit(&d.pool);
        d.tree = next;
    }
}

fn retainRelease(d: *Doc, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var c = d.tree.clone();
        c.deinit(&d.pool);
    }
}

/// Undo then redo of one 10k-replacement group (the applies dominate).
fn undo10k(d: *Doc, s: *bench.State) void {
    const edit = zg_editor.model.edit;
    const gpa = std.heap.smp_allocator;
    var edits: [10_000]buffer.piece_tree.Edit = undefined;
    const step = d.tree.len() / edits.len;
    for (&edits, 0..) |*e, k| e.* = .{ .range = .{ .start = k * step, .end = k * step + 1 }, .text = "zz" };
    const cs = edit.change_set.ChangeSet.fromEdits(gpa, d.tree.len(), &edits) catch unreachable;
    const inv = cs.invert(d.tree, gpa) catch unreachable;
    const next = cs.apply(d.tree, &d.pool) catch unreachable;
    d.tree.deinit(&d.pool);
    d.tree = next;
    var tree: edit.undo.UndoTree = .init(gpa, .{});
    defer tree.deinit();
    tree.record(cs, inv, &.{}, &.{}, .{ .origin = .{ .user = 0 }, .timestamp = .zero }) catch unreachable;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        inline for (.{ edit.undo.UndoTree.undo, edit.undo.UndoTree.redo }) |f| {
            const st = f(&tree).?;
            const t = st.changes.apply(d.tree, &d.pool) catch unreachable;
            d.tree.deinit(&d.pool);
            d.tree = t;
        }
    }
}

/// A modified copy of `text` with `hunks` scattered single-line changes.
fn mutateLines(gpa: std.mem.Allocator, text: []const u8, hunks: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const lines = std.mem.count(u8, text, "\n");
    const every = lines / hunks;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (line.len == 0 and it.peek() == null) break;
        if (every > 0 and i % every == every / 2) try out.appendSlice(gpa, "changed line\n");
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const DiffPair = struct {
    a: zg_editor.model.diff.LineSource,
    b: zg_editor.model.diff.LineSource,
};

fn diffPair(p: *DiffPair, s: *bench.State) void {
    const diff = zg_editor.model.diff;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var r = diff.diffLines(std.heap.smp_allocator, &p.a, &p.b, .{}) catch unreachable;
        bench.doNotOptimizeAway(r.hunks.len);
        r.deinit(std.heap.smp_allocator);
    }
}

fn diffMoves(p: *DiffPair, s: *bench.State) void {
    const diff = zg_editor.model.diff;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var r = diff.diffLines(std.heap.smp_allocator, &p.a, &p.b, .{ .detect_moves = true, .intraline = .none }) catch unreachable;
        bench.doNotOptimizeAway(r.moves.len);
        r.deinit(std.heap.smp_allocator);
    }
}

/// Word highlights for one changed line pair (a typical small hunk).
fn intralineHunk(p: *DiffPair, s: *bench.State) void {
    const diff = zg_editor.model.diff;
    const edits = [_]diff.Edit{ .{ .kind = .delete, .a_start = 0, .b_start = 0, .len = 2 }, .{ .kind = .insert, .a_start = 2, .b_start = 0, .len = 2 } };
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const r = diff.intraline.intralineEdits(std.heap.smp_allocator, &edits, &p.a, &p.b, .word) catch unreachable;
        bench.doNotOptimizeAway(r.len);
        std.heap.smp_allocator.free(r);
    }
}

const FindDoc = struct { doc: *zg_editor.model.document.Document };

/// Literal find-all over the whole document (bytes/s = len / time).
fn findAll(f: *FindDoc, s: *bench.State) void {
    findAllCase(f, s, .sensitive);
}

/// Case-insensitive literal find-all (the smart-case default for "needle").
fn findAllIcase(f: *FindDoc, s: *bench.State) void {
    findAllCase(f, s, .insensitive);
}

fn findAllCase(f: *FindDoc, s: *bench.State, case: @FieldType(zg_editor.model.search.find.FindOptions, "case")) void {
    const find = zg_editor.model.search.find;
    s.setBytes(f.doc.len());
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var fs = find.FindSession.start(std.heap.smp_allocator, f.doc, .{ .pattern = "needle", .case = case }, .{ .start = 0, .end = 0 }, null) catch unreachable;
        fs.finish() catch unreachable;
        bench.doNotOptimizeAway(fs.matchCount().known);
        fs.stop();
    }
}

/// Viewport search (100 lines) in the middle of the document.
fn findViewport(f: *FindDoc, s: *bench.State) void {
    const find = zg_editor.model.search.find;
    const mid = f.doc.tree.lineStart(f.doc.tree.lineCount() / 2);
    const end = f.doc.tree.lineStart(f.doc.tree.lineCount() / 2 + 100);
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var fs = find.FindSession.start(std.heap.smp_allocator, f.doc, .{ .pattern = "needle" }, .{ .start = mid, .end = end }, null) catch unreachable;
        bench.doNotOptimizeAway(fs.matchCount().known);
        fs.stop();
    }
}

/// Replace all ~100k matches in a 10 MB document (alternating directions
/// so every iteration replaces the same number).
fn replaceAll(f: *FindDoc, s: *bench.State) void {
    const find = zg_editor.model.search.find;
    const gpa = std.heap.smp_allocator;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const from, const to = if (i % 2 == 0) .{ "needle", "NEEDLE" } else .{ "NEEDLE", "needle" };
        var fs = find.FindSession.start(gpa, f.doc, .{ .pattern = from, .case = .sensitive }, .{ .start = 0, .end = 0 }, null) catch unreachable;
        bench.doNotOptimizeAway(fs.replaceAll(to, .{ .user = 0 }) catch unreachable);
        fs.stop();
        f.doc.endFrame();
    }
}

fn registerFind(b: *bench.Bench) !void {
    const Document = zg_editor.model.document.Document;
    inline for (.{
        .{ "editor.find.all_literal_100mb", 100 << 20, findAll, 10 },
        .{ "editor.find.all_literal_icase_100mb", 100 << 20, findAllIcase, 10 },
        .{ "editor.find.viewport_100mb", 100 << 20, findViewport, 10 },
        .{ "editor.replace.all_100k", 10 << 20, replaceAll, 1 },
    }) |c| {
        // Lines of 100 bytes; one in c[3] holds "needle" (100k in 10 MB).
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(b.gpa);
        try text.ensureTotalCapacity(b.gpa, c[1]);
        var k: usize = 0;
        while (text.items.len < c[1]) : (k += 1) {
            try text.appendSlice(b.gpa, "the quick brown fox jumps over the lazy dog; and then some more words, ");
            try text.appendSlice(b.gpa, if (k % c[3] == 0) "a needle in the hay\n" else "nothing in the hay\n");
        }
        const doc = try Document.initBytes(b.gpa, @enumFromInt(1), text.items);
        defer doc.deinit();
        var f: FindDoc = .{ .doc = doc };
        try b.run(c[0], &f, c[2]);
    }
}

fn registerDiff(b: *bench.Bench) !void {
    {
        var p: DiffPair = .{
            .a = try .fromBytes(b.gpa, "    const total = computeTotal(items, options.include_tax, rate);\n    return total * scale;\n"),
            .b = try .fromBytes(b.gpa, "    const subtotal = computeTotal(items, options.include_shipping, rate);\n    return subtotal * scale;\n"),
        };
        defer p.a.deinit(b.gpa);
        defer p.b.deinit(b.gpa);
        try b.run("editor.diff.intraline_hunk", &p, intralineHunk);
    }
    {
        // 10k lines with 100 eight-line blocks moved 50 lines down.
        const a_text = try genLines(b.gpa, 10_000);
        defer b.gpa.free(a_text);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(b.gpa);
        var it = std.mem.splitScalar(u8, a_text, '\n');
        while (it.next()) |l| if (l.len > 0) try lines.append(b.gpa, l);
        var k: usize = 0;
        while (k + 58 < lines.items.len) : (k += 100) {
            std.mem.rotate([]const u8, lines.items[k .. k + 58], 8);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        for (lines.items) |l| {
            try out.appendSlice(b.gpa, l);
            try out.append(b.gpa, '\n');
        }
        var p: DiffPair = .{ .a = try .fromBytes(b.gpa, a_text), .b = try .fromBytes(b.gpa, out.items) };
        defer p.a.deinit(b.gpa);
        defer p.b.deinit(b.gpa);
        try b.run("editor.diff.moves_10k", &p, diffMoves);
    }
    const diff = zg_editor.model.diff;
    inline for (.{
        .{ "editor.diff.10k_100hunks", 10_000, 100, false },
        .{ "editor.diff.100k_1khunks", 100_000, 1000, false },
        .{ "editor.diff.unrelated_100k", 100_000, 0, true },
    }) |c| {
        const a_text = try genLines(b.gpa, c[1]);
        defer b.gpa.free(a_text);
        const b_text = if (c[3]) blk: {
            const t = try b.gpa.dupe(u8, a_text);
            std.mem.reverse(u8, t);
            break :blk t;
        } else try mutateLines(b.gpa, a_text, c[2]);
        defer b.gpa.free(b_text);
        var p: DiffPair = .{ .a = try .fromBytes(b.gpa, a_text), .b = try .fromBytes(b.gpa, b_text) };
        defer p.a.deinit(b.gpa);
        defer p.b.deinit(b.gpa);
        _ = diff;
        try b.run(c[0], &p, diffPair);
    }
}

fn register(b: *bench.Bench) !void {
    for (pending) |name| if (b.opts.filter == null or std.mem.indexOf(u8, name, b.opts.filter.?) != null)
        std.debug.print("{s:<40} skipped (not implemented yet)\n", .{name});

    const text = try genLines(b.gpa, 100_000);
    defer b.gpa.free(text);
    inline for (.{
        .{ "editor.buffer.insert_char_100k", insertChar },
        .{ "editor.buffer.type_char_100k", typeChar },
        .{ "editor.buffer.offset_to_point", offsetToPoint },
        .{ "editor.buffer.offset_to_utf16", offsetToUtf16 },
        .{ "editor.buffer.replace_1k_cursors", replace1k },
        .{ "editor.snapshot.retain_release", retainRelease },
        .{ "editor.undo.10k_group", undo10k },
    }) |entry| {
        const d = try Doc.init(b.gpa, text);
        defer d.deinit(b.gpa);
        try b.run(entry[0], d, entry[1]);
    }
    try registerDiff(b);
    try registerFind(b);
    try registerLspSync(b, text);
    try registerDecorations(b, text);
    try registerAiOverlays(b, text);
    try registerAgentEdit(b, text);
    try registerCursors(b, text);
    try registerMoves(b, text);
    try registerSmart(b, text);
}

const MoveBench = struct { snap: zg_editor.model.snapshot.Snapshot, unit: zg_editor.model.edit.movement.Unit };

/// One move by `unit` from scattered positions in a 100k-line document,
/// alternating direction.
fn registerMoves(b: *bench.Bench, text: []const u8) !void {
    const doc = try zg_editor.model.document.Document.initBytes(b.gpa, @enumFromInt(1), text);
    defer doc.deinit();
    inline for (.{
        .{ "editor.move.grapheme_100k", .grapheme },
        .{ "editor.move.word_100k", .word },
        .{ "editor.move.subword_100k", .subword },
        .{ "editor.move.buffer_line_100k", .buffer_line },
        .{ "editor.move.smart_home_100k", .smart_home },
        .{ "editor.move.paragraph_100k", .paragraph },
    }) |c| {
        var mb: MoveBench = .{ .snap = doc.snapshot(), .unit = c[1] };
        defer mb.snap.release();
        try b.run(c[0], &mb, moveOnce);
    }
}

fn moveOnce(m: *MoveBench, s: *bench.State) void {
    const movement = zg_editor.model.edit.movement;
    var rng: std.Random.DefaultPrng = .init(7);
    const r = rng.random();
    const len = m.snap.len();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const at = r.uintLessThan(u64, len);
        const dir: movement.Dir = if (i & 1 == 0) .forward else .backward;
        bench.doNotOptimizeAway(movement.move(&m.snap, at, m.unit, dir, .{}));
    }
}

const CursorBench = struct { doc: *zg_editor.model.document.Document, sels: *zg_editor.model.edit.selection.SelectionSet };

/// Typing with `n` carets spread over a 100k-line document: one
/// ChangeSet per keystroke, applied, with every caret placed after its
/// text (edit pipeline without syntax).
fn registerCursors(b: *bench.Bench, text: []const u8) !void {
    const edit = zg_editor.model.edit;
    inline for (.{ .{ "editor.edit.type_1k_cursors", 1_000 }, .{ "editor.edit.type_10k_cursors", 10_000 } }) |c| {
        const doc = try zg_editor.model.document.Document.initBytes(b.gpa, @enumFromInt(1), text);
        defer doc.deinit();
        var sels = try edit.selection.SelectionSet.init(b.gpa, .caret(0));
        defer sels.deinit();
        const lines = doc.tree.lineCount() - 1;
        const carets = try b.gpa.alloc(edit.selection.Selection, c[1]);
        defer b.gpa.free(carets);
        for (carets, 0..) |*sel, i| sel.* = .caret(doc.tree.lineStart(i * lines / c[1]) + 5);
        try sels.set(carets, 0);
        var cb: CursorBench = .{ .doc = doc, .sels = &sels };
        try b.run(c[0], &cb, typeCursors);
    }
}

fn typeCursors(c: *CursorBench, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        _ = zg_editor.model.edit.runner.typeText(c.doc, c.sels, "x", .{ .user = 0 }) catch unreachable;
        c.doc.endFrame();
    }
}

const SmartBench = struct {
    doc: *zg_editor.model.document.Document,
    sels: *zg_editor.model.edit.selection.SelectionSet,
    ap: *zg_editor.model.edit.pairs.AutoPairs,
};

/// Smart typing with one and 1k carets over a 100k-line Zig document: an
/// auto-closing `(` typed at each, and Enter (auto-indent) at each. No
/// syntax tokens, so this is the edit pipeline plus the indent rules.
fn registerSmart(b: *bench.Bench, text: []const u8) !void {
    const edit = zg_editor.model.edit;
    inline for (.{
        .{ "editor.smart.type_autoclose", typeAutoClose, 1 },
        .{ "editor.smart.type_autoclose_1k_cursors", typeAutoClose, 1_000 },
        .{ "editor.smart.newline_1k_cursors", newlineCursors, 1_000 },
    }) |c| {
        const doc = try zg_editor.model.document.Document.initBytes(b.gpa, @enumFromInt(1), text);
        defer doc.deinit();
        var sels = try edit.selection.SelectionSet.init(b.gpa, .caret(0));
        defer sels.deinit();
        var ap: edit.pairs.AutoPairs = .{ .gpa = b.gpa };
        defer ap.deinit();
        const n = c[2];
        const lines = doc.tree.lineCount() - 1;
        const carets = try b.gpa.alloc(edit.selection.Selection, n);
        defer b.gpa.free(carets);
        for (carets, 0..) |*sel, i| {
            const l = i * lines / n;
            sel.* = .caret(doc.tree.lineStart(l + 1) - 1);
        }
        try sels.set(carets, 0);
        var sb: SmartBench = .{ .doc = doc, .sels = &sels, .ap = &ap };
        try b.run(c[0], &sb, c[1]);
    }
}

fn smartCtx(c: *SmartBench) zg_editor.model.edit.smart_edit.EditCtx {
    return .{ .lang = &zg_syntax.langs.zig.zig_language, .auto_pairs = c.ap };
}

fn typeAutoClose(c: *SmartBench, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        _ = zg_editor.model.edit.smart_edit.typeChar(c.doc, c.sels, '(', smartCtx(c)) catch unreachable;
        c.ap.clear();
        c.doc.endFrame();
    }
}

fn newlineCursors(c: *SmartBench, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        _ = zg_editor.model.edit.smart_edit.newline(c.doc, c.sels, smartCtx(c)) catch unreachable;
        c.doc.endFrame();
    }
}

const AgentBench = struct {
    session: *api.agent_edit.AgentEditSession,
    h: api.registry.DocHandle,
    cs: *const zg_editor.model.edit.change_set.ChangeSet,
    base: u64,

    fn deny(_: *anyopaque, _: u64, _: api.registry.DocHandle, _: api.agent_edit.ProposalSummary) api.agent_edit.Decision {
        return .deny;
    }
};

fn registerAgentEdit(b: *bench.Bench, text: []const u8) !void {
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    var reg: api.registry.DocumentRegistry = .init(b.gpa, .posix);
    defer reg.deinit();
    const h = try reg.openFile("/bench.zig", text);
    defer reg.release(h);
    var dummy: u8 = 0;
    var session: api.agent_edit.AgentEditSession = .init(b.gpa, &reg, 1, .{ .ctx = &dummy, .decide = AgentBench.deny });
    defer session.deinit();
    const doc = reg.get(h).?;
    const base = doc.version;
    // The agent edits 20 places in the second half...
    var edits: [20]buffer.piece_tree.Edit = undefined;
    for (&edits, 0..) |*e, i| {
        const st = doc.tree.lineStart(60_000 + i * 1000);
        e.* = .{ .range = .{ .start = st, .end = st + 5 }, .text = "agent" };
    }
    var cs = try ChangeSet.fromEdits(b.gpa, doc.len(), &edits);
    defer cs.deinit();
    // ...while the user types 100 characters in the first half.
    for (0..100) |i| {
        const at = doc.tree.lineStart(1000 + i * 10);
        var u = try ChangeSet.fromEdits(b.gpa, doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = "u" }});
        defer u.deinit();
        try doc.applyChangeSet(&u, .{ .user = 0 });
    }
    var ab: AgentBench = .{ .session = &session, .h = h, .cs = &cs, .base = base };
    try b.run("editor.agent.rebase_100_edits", &ab, agentRebase);
}

/// Validates and rebases a 20-replace proposal over 100 user edits (the
/// policy denies it, so nothing is applied).
fn agentRebase(a: *AgentBench, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var o = a.session.propose(a.h, .{ .change_set = .{ .cs = a.cs, .base_version = a.base } }, "bench") catch unreachable;
        std.debug.assert(o == .rejected and o.rejected == .denied);
        o.deinit(std.heap.smp_allocator);
    }
}

const AiBench = struct {
    doc: *zg_editor.model.document.Document,
    store: *deco.DecorationStore,
    owner: deco.OwnerId,
    pending: ?*zg_editor.model.decorations.pending.PendingChange = null,
    ghost: ?*zg_editor.model.decorations.ghost.GhostText = null,

    fn onChange(ctx: *anyopaque, ev: *const zg_editor.model.document.ChangeEvent) void {
        const a: *AiBench = @ptrCast(@alignCast(ctx));
        if (a.pending) |p| p.onChange(ev) catch unreachable;
        if (a.ghost) |g| _ = g.onType(ev) catch unreachable;
    }
};

fn registerAiOverlays(b: *bench.Bench, text: []const u8) !void {
    const Document = zg_editor.model.document.Document;
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    const doc = try Document.initBytes(b.gpa, @enumFromInt(1), text);
    defer doc.deinit();
    var store: deco.DecorationStore = .init(b.gpa, doc);
    defer store.deinit();
    _ = try doc.subscribe(store.listener());
    var ab: AiBench = .{ .doc = doc, .store = &store, .owner = try store.registerOwner("ai", 0) };
    _ = try doc.subscribe(.{ .ctx = &ab, .onChange = AiBench.onChange });
    {
        // 50 hunks spread over the second half of the document.
        var edits: [50]buffer.piece_tree.Edit = undefined;
        for (&edits, 0..) |*e, i| {
            const st = doc.tree.lineStart(50_000 + i * 900);
            e.* = .{ .range = .{ .start = st, .end = st + 10 }, .text = "agent text" };
        }
        var cs = try ChangeSet.fromEdits(b.gpa, doc.len(), &edits);
        defer cs.deinit();
        ab.pending = try zg_editor.model.decorations.pending.PendingChange.create(b.gpa, doc, &store, ab.owner, &cs, doc.version, "bench", .{ .agent = 1 }, .{});
        defer {
            ab.pending.?.destroy();
            ab.pending = null;
        }
        try b.run("editor.pending.rebase_50_hunks", &ab, typeAtTop);
    }
    {
        const ghost_owner = try store.registerOwner("ai.ghost", 0);
        const at = doc.tree.lineStart(1000);
        const g_text = "a" ** 4096;
        var g = try zg_editor.model.decorations.ghost.GhostText.show(b.gpa, doc, &store, at, g_text, .{ .request_id = 1, .source = ghost_owner });
        defer g.deinit();
        ab.ghost = &g;
        defer ab.ghost = null;
        try b.run("editor.ghost.type_through", &ab, typeThrough);
    }
}

/// A typed character at the top of the document; the pending change
/// rebases its 50 hunks.
fn typeAtTop(a: *AiBench, s: *bench.State) void {
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var cs = ChangeSet.fromEdits(std.heap.smp_allocator, a.doc.len(), &.{.{ .range = .{ .start = 3, .end = 3 }, .text = "x" }}) catch unreachable;
        a.doc.applyChangeSet(&cs, .{ .user = 0 }) catch unreachable;
        cs.deinit();
        a.doc.endFrame();
    }
}

/// Typing the next character of a ghost (re-shown when it runs out).
fn typeThrough(a: *AiBench, s: *bench.State) void {
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    const g = a.ghost.?;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        if (g.remaining().len < 2) {
            g.text.appendNTimes(std.heap.smp_allocator, 'a', 4096) catch unreachable;
        }
        var cs = ChangeSet.fromEdits(std.heap.smp_allocator, a.doc.len(), &.{.{ .range = .{ .start = g.at, .end = g.at }, .text = "a" }}) catch unreachable;
        a.doc.applyChangeSet(&cs, .{ .user = 0 }) catch unreachable;
        cs.deinit();
        a.doc.endFrame();
    }
}

const deco = zg_editor.model.decorations.store;

const DecoBench = struct {
    doc: *zg_editor.model.document.Document,
    store: *deco.DecorationStore,
    owner: deco.OwnerId,
    set: []deco.Decoration,
};

fn registerDecorations(b: *bench.Bench, text: []const u8) !void {
    const Document = zg_editor.model.document.Document;
    const doc = try Document.initBytes(b.gpa, @enumFromInt(1), text);
    defer doc.deinit();
    var store: deco.DecorationStore = .init(b.gpa, doc);
    defer store.deinit();
    _ = try doc.subscribe(store.listener());
    const owner = try store.registerOwner("lsp.diagnostics", 10);
    // 100k diagnostics, one per line.
    const set = try b.gpa.alloc(deco.Decoration, doc.tree.lineCount() - 1);
    defer b.gpa.free(set);
    for (set, 0..) |*d, i| {
        const st = doc.tree.lineStart(i);
        d.* = .{ .range = .{ .start = st + 2, .end = st + 8 }, .owner = owner, .kind = .{ .underline = .{ .style = @enumFromInt(1) } } };
    }
    var db: DecoBench = .{ .doc = doc, .store = &store, .owner = owner, .set = set };
    try b.run("editor.deco.replace_100k", &db, decoReplace);
    var db10k = db;
    db10k.set = set[0..10_000];
    try b.run("editor.deco.replace_10k", &db10k, decoReplace);
    try store.setOwnerDecorations(owner, doc.version, set);
    try b.run("editor.deco.viewport_query_100k", &db, decoQuery);
    try b.run("editor.deco.edit_shift_100k", &db, decoEdit);
}

/// Replaces an owner's 100k decorations (LSP diagnostics push).
fn decoReplace(d: *DecoBench, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        d.store.setOwnerDecorations(d.owner, d.doc.version, d.set) catch unreachable;
    }
}

/// 80 visible lines in the middle of 100k decorated lines.
fn decoQuery(d: *DecoBench, s: *bench.State) void {
    const mid = d.doc.tree.lineCount() / 2;
    const r: zg_editor.model.buffer.piece_tree.Range = .{ .start = d.doc.tree.lineStart(mid), .end = d.doc.tree.lineStart(mid + 80) };
    var out: std.ArrayList(deco.DecoRef) = .empty;
    defer out.deinit(std.heap.smp_allocator);
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        out.clearRetainingCapacity();
        d.store.query(r, .initFull(), std.heap.smp_allocator, &out) catch unreachable;
        bench.doNotOptimizeAway(out.items.len);
    }
}

/// A typed character at the top of the document: every later decoration
/// moves (one tree shift) and the decoration on that line is remapped.
fn decoEdit(d: *DecoBench, s: *bench.State) void {
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var cs = ChangeSet.fromEdits(std.heap.smp_allocator, d.doc.len(), &.{.{ .range = .{ .start = 4, .end = 4 }, .text = "x" }}) catch unreachable;
        d.doc.applyChangeSet(&cs, .{ .user = 0 }) catch unreachable;
        cs.deinit();
        d.doc.endFrame();
    }
}

const api = zg_editor.model.api;

const NullSink = struct {
    fn didOpen(_: *anyopaque, _: []const u8, _: []const u8, _: i32, _: buffer.piece_tree.ChunkIterator) void {}
    fn didChange(_: *anyopaque, _: []const u8, v: i32, changes: []const api.lsp_sync.LspChange, _: ?buffer.piece_tree.ChunkIterator) void {
        bench.doNotOptimizeAway(v);
        bench.doNotOptimizeAway(changes.len);
    }
    fn didSave(_: *anyopaque, _: []const u8, _: ?buffer.piece_tree.ChunkIterator) void {}
    fn didClose(_: *anyopaque, _: []const u8) void {}
};

const SyncDoc = struct { reg: *api.registry.DocumentRegistry, sync: *api.lsp_sync.LspSync, h: api.registry.DocHandle };

fn registerLspSync(b: *bench.Bench, text: []const u8) !void {
    var reg: api.registry.DocumentRegistry = .init(b.gpa, .posix);
    defer reg.deinit();
    var dummy: u8 = 0;
    var sync: api.lsp_sync.LspSync = .init(b.gpa, &reg, .utf16, .incremental, .{
        .ctx = &dummy,
        .didOpen = NullSink.didOpen,
        .didChange = NullSink.didChange,
        .didSave = NullSink.didSave,
        .didClose = NullSink.didClose,
    });
    defer sync.deinit();
    const h = try reg.openFile("/bench.txt", text);
    defer reg.release(h);
    try sync.track(h, "plaintext");
    var d: SyncDoc = .{ .reg = &reg, .sync = &sync, .h = h };
    try b.run("editor.lsp_sync.keystroke_100k", &d, lspKeystroke);
}

/// One typed character in the middle of a 100k-line document, then the
/// frame's flush: ChangeSet, compose and UTF-16 positions.
fn lspKeystroke(d: *SyncDoc, s: *bench.State) void {
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    const doc = d.reg.get(d.h).?;
    var at = doc.tree.lineStart(doc.tree.lineCount() / 2) + 10;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var cs = ChangeSet.fromEdits(std.heap.smp_allocator, doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = "x" }}) catch unreachable;
        doc.applyChangeSet(&cs, .{ .user = 0 }) catch unreachable;
        cs.deinit();
        d.sync.flush();
        doc.endFrame();
        at += 1;
    }
}
