//! Expand and shrink selection (E07.F03.S02.T02, `editor.expandSelection`
//! Shift+Alt+Right, `editor.shrinkSelection` Shift+Alt+Left): expanding
//! asks the language server for the selection ranges at every cursor
//! (`textDocument/selectionRange`) and grows each selection to the next
//! larger range around it; without a server, or when its answer comes
//! after an edit, the editor's own structure gives the ranges (syntax
//! node spans). Pressing again walks further out along the same chains
//! without asking; shrinking steps back through the selections the
//! expands started from. An edit or a selection change elsewhere starts
//! over.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const EditorView = zg_editor.view.EditorView;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Selection = zg_editor.model.edit.selection.Selection;
const SelectionDriver = zg_codeintel.features.SelectionDriver;
const ByteRange = SelectionDriver.ByteRange;
const Manager = zg_codeintel.Manager;

pub const SmartSelect = struct {
    /// The editor's own structure of `h` at its current version, with
    /// node spans where the language has a parser (null: none yet).
    pub const StructureFn = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, h: DocHandle, gpa: Allocator) ?zg_syntax.Structure,
    };

    gpa: Allocator,
    driver: SelectionDriver,
    structure: ?StructureFn = null,
    /// The chains of the last answer, one per selection, innermost first
    /// (in `arena`), for `view` at `version`.
    arena: std.heap.ArenaAllocator,
    chains: []const []const ByteRange = &.{},
    view: ?*EditorView = null,
    version: u64 = 0,
    /// The selections set last: another selection means the user moved.
    last: std.ArrayList(Selection) = .empty,
    /// The selections each expand started from, oldest first.
    history: std.ArrayList([]Selection) = .empty,
    /// An expand waiting for the server.
    pending: ?struct { view: *EditorView, h: DocHandle, version: u64 } = null,
    /// Bumped whenever a selection changed here (repaint).
    generation: u64 = 0,

    pub fn init(gpa: Allocator, mgr: *Manager, waker: zg_core.runtime.Waker) SmartSelect {
        return .{ .gpa = gpa, .driver = .init(mgr, waker), .arena = .init(gpa) };
    }

    /// Before the editors go: forgets them (the driver after
    /// `Manager.deinit`, `deinitDriver`).
    pub fn release(s: *SmartSelect) void {
        s.reset();
        s.pending = null;
    }

    pub fn deinitDriver(s: *SmartSelect) void {
        s.driver.deinit();
        s.reset();
        s.arena.deinit();
        s.last.deinit(s.gpa);
        s.history.deinit(s.gpa);
    }

    /// `view` closed or shows another file.
    pub fn forgetView(s: *SmartSelect, view: *EditorView) void {
        if (s.view == view) s.reset();
        if (s.pending) |p| if (p.view == view) {
            s.pending = null;
        };
    }

    fn reset(s: *SmartSelect) void {
        for (s.history.items) |h| s.gpa.free(h);
        s.history.clearRetainingCapacity();
        s.last.clearRetainingCapacity();
        s.chains = &.{};
        _ = s.arena.reset(.retain_capacity);
        s.view = null;
    }

    /// Whether the chains still describe `view`'s selections.
    fn current(s: *const SmartSelect, view: *EditorView) bool {
        if (s.view != view or view.doc.version != s.version) return false;
        const sels = view.selections();
        return sels.len == s.chains.len and zg_editor.model.edit.selection.eql(sels, s.last.items);
    }

    /// Grows every selection of `view` (showing `h`) one step.
    pub fn expand(s: *SmartSelect, view: *EditorView, h: DocHandle) void {
        if (s.current(view)) {
            s.step(view);
            return;
        }
        s.reset();
        s.pending = .{ .view = view, .h = h, .version = view.doc.version };
        var heads: std.ArrayList(u64) = .empty;
        defer heads.deinit(s.gpa);
        for (view.selections()) |sel| heads.append(s.gpa, sel.head) catch return;
        s.driver.request(h, heads.items, .{ .ctx = s, .func = onAnswer }) catch {
            s.pending = null;
        };
    }

    /// Back to the selections the previous expand started from.
    pub fn shrink(s: *SmartSelect, view: *EditorView) void {
        if (!s.current(view) or s.history.items.len == 0) return;
        const prev = s.history.pop().?;
        defer s.gpa.free(prev);
        s.set(view, prev, view.sels.primaryIndex());
    }

    /// Delivers server answers.
    pub fn tick(s: *SmartSelect) void {
        s.driver.tick();
    }

    fn onAnswer(ctx: *anyopaque, h: DocHandle, a: SelectionDriver.Answer) void {
        const s: *SmartSelect = @ptrCast(@alignCast(ctx));
        const p = s.pending orelse return;
        if (!std.meta.eql(p.h, h)) return;
        s.pending = null;
        const view = p.view;
        // Too late: the text changed since the ask.
        if (view.doc.version != p.version) return;
        const sels = view.selections();
        const al = s.arena.allocator();
        const chains = al.alloc([]const ByteRange, sels.len) catch return;
        switch (a) {
            .chains => |cs| {
                if (cs.len != sels.len) return;
                for (cs, chains) |c, *out| out.* = al.dupe(ByteRange, c) catch return;
            },
            .fallback => s.fromStructure(view, h, sels, chains) catch return,
        }
        s.chains = chains;
        s.view = view;
        s.version = p.version;
        s.last.clearRetainingCapacity();
        s.last.appendSlice(s.gpa, sels) catch return s.reset();
        s.step(view);
    }

    /// Chains from the editor's structure: the word at each head, the
    /// syntax node spans (or the enclosing scopes) around it, its line,
    /// the whole text.
    fn fromStructure(s: *SmartSelect, view: *EditorView, h: DocHandle, sels: []const Selection, out: [][]const ByteRange) !void {
        const al = s.arena.allocator();
        var st: ?zg_syntax.Structure = if (s.structure) |f| f.f(f.ctx, h, s.gpa) else null;
        defer if (st) |*x| x.deinit();
        var spans: std.ArrayList(zg_syntax.ByteRange) = .empty;
        defer spans.deinit(s.gpa);
        var scopes: std.ArrayList(zg_syntax.Scope) = .empty;
        defer scopes.deinit(s.gpa);
        var list: std.ArrayList(ByteRange) = .empty;
        defer list.deinit(s.gpa);
        const len = view.doc.len();
        for (sels, out) |sel, *chain| {
            list.clearRetainingCapacity();
            const head = sel.head;
            const line = view.lineRange(view.lineOf(head));
            if (wordAt(view.text(line), head - line.start)) |w| try list.append(s.gpa, .{ .start = line.start + w[0], .end = line.start + w[1] });
            if (st) |*x| {
                const pos: u32 = @intCast(@min(head, std.math.maxInt(u32)));
                try x.selectionRanges(s.gpa, pos, &spans);
                for (spans.items) |r| try list.append(s.gpa, .{ .start = r.start, .end = r.end });
                if (spans.items.len == 0) {
                    try x.enclosingScopes(s.gpa, pos, &scopes);
                    for (scopes.items) |sc| try list.append(s.gpa, .{ .start = sc.range.start, .end = sc.range.end });
                }
            }
            const trimmed = trimLine(view.text(line));
            if (trimmed[1] > trimmed[0]) try list.append(s.gpa, .{ .start = line.start + trimmed[0], .end = line.start + trimmed[1] });
            try list.append(s.gpa, .{ .start = 0, .end = len });
            chain.* = try al.dupe(ByteRange, nest(list.items));
        }
    }

    /// Sorts `rs` by size and keeps a nested chain: each range holds the
    /// one before it.
    fn nest(rs: []ByteRange) []ByteRange {
        std.mem.sort(ByteRange, rs, {}, struct {
            fn lt(_: void, a: ByteRange, b: ByteRange) bool {
                return a.end - a.start < b.end - b.start;
            }
        }.lt);
        var n: usize = 0;
        for (rs) |r| {
            if (n > 0) {
                const inner = rs[n - 1];
                if (r.start > inner.start or r.end < inner.end) continue;
                if (r.start == inner.start and r.end == inner.end) continue;
            }
            rs[n] = r;
            n += 1;
        }
        return rs[0..n];
    }

    /// The identifier around column byte `col` of `line`, as `[start, end)`.
    fn wordAt(line: []const u8, col: u64) ?[2]u64 {
        const c: usize = @intCast(@min(col, line.len));
        var a = c;
        while (a > 0 and isWord(line[a - 1])) a -= 1;
        var b = c;
        while (b < line.len and isWord(line[b])) b += 1;
        return if (b > a) .{ a, b } else null;
    }

    fn isWord(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
    }

    /// The line without its indentation, trailing blanks and line break.
    fn trimLine(line: []const u8) [2]u64 {
        var a: usize = 0;
        while (a < line.len and (line[a] == ' ' or line[a] == '\t')) a += 1;
        var b = line.len;
        while (b > a and std.ascii.isWhitespace(line[b - 1])) b -= 1;
        return .{ a, b };
    }

    /// One step out for every selection that has a larger range.
    fn step(s: *SmartSelect, view: *EditorView) void {
        const sels = view.selections();
        const next = s.gpa.alloc(Selection, sels.len) catch return;
        defer s.gpa.free(next);
        var moved = false;
        for (sels, s.chains, next) |sel, chain, *n| {
            n.* = sel;
            const r = SelectionDriver.expand(chain, .{ .start = sel.start(), .end = sel.end() }) orelse continue;
            n.* = .{ .anchor = r.start, .head = r.end };
            moved = true;
        }
        if (!moved) return;
        const before = s.gpa.dupe(Selection, sels) catch return;
        s.history.append(s.gpa, before) catch return s.gpa.free(before);
        s.set(view, next, view.sels.primaryIndex());
    }

    fn set(s: *SmartSelect, view: *EditorView, sels: []const Selection, primary: usize) void {
        view.setSelections(sels, primary) catch return;
        s.last.clearRetainingCapacity();
        s.last.appendSlice(s.gpa, view.selections()) catch return s.reset();
        // Merged selections no longer line up with the chains.
        if (view.selections().len != s.chains.len) s.reset();
        s.generation += 1;
    }
};
