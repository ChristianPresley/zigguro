//! The notes sidebar's state (E08.F06.S01.T04): backlinks (linked, and
//! unlinked on demand), outgoing links, the tag tree and the active
//! note's properties, rebuilt from the latest `IndexView` when the active
//! note or the index changes.
//!
//! Threads: the model lives on the UI thread. Index events (any thread)
//! only mark it dirty and `Notify` the UI, which calls `sync` before
//! building. Unlinked mentions run through `Spawn` and land only if the
//! active note has not changed since (a generation check).

const std = @import("std");
const zg_notes = @import("zg_notes");
const zg_gui = @import("zg_gui");
const ports = @import("ports.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = zg_notes.FileId;
const IndexView = zg_notes.IndexView;
const NoteIndex = zg_notes.NoteIndex;
const TagNode = zg_notes.index.tag_tree.TagNode;
const Mention = zg_notes.index.mentions.Mention;
const ContentSource = zg_notes.index.mentions.ContentSource;
const Value = zg_notes.frontmatter.Value;
const PropertyType = zg_notes.note.PropertyType;
const TreeSource = zg_gui.virtual.TreeSource;
const ChildCount = zg_gui.virtual.tree_view.ChildCount;

pub const BacklinkRow = struct {
    /// The line holding the link.
    text: []const u8,
    /// The link within `text`.
    highlight: [2]u32,
    /// The line's range in the source note.
    range: [2]u32,
};

pub const BacklinkGroup = struct {
    source: FileId,
    title: []const u8,
    path: []const u8,
    rows: []const BacklinkRow,
};

pub const OutKind = enum { note, attachment, self, ambiguous, unresolved };

pub const OutLink = struct {
    /// The target as written.
    target: []const u8,
    kind: OutKind,
    /// The resolved note (the tie-break winner when ambiguous).
    path: ?[]const u8 = null,
    /// Every match of an ambiguous link.
    candidates: []const []const u8 = &.{},
    /// Where "Create note" puts an unresolved link's note.
    create_path: ?[]const u8 = null,
};

pub const UnlinkedRow = struct {
    mention: Mention,
    source_title: []const u8,
    source_path: []const u8,
    text: []const u8,
    highlight: [2]u32,
};

pub const Unlinked = union(enum) {
    /// Not asked for (the section is collapsed).
    idle,
    running,
    done: []const UnlinkedRow,
    failed: []const u8,
};

pub const PropRow = struct {
    name: []const u8,
    /// The registry type (`IndexView.propertyType`).
    ty: PropertyType,
    value: Value,
    /// The value's source text.
    raw: []const u8,
    /// The value implies another type than the registry's.
    conflict: bool,
};

pub const TagSort = enum { name, count };

pub const Options = struct {
    gpa: Allocator,
    io: Io,
    ix: *NoteIndex,
    vault: *const zg_notes.Vault,
    /// Note bytes (the open document's snapshot, else the file).
    content: ContentSource,
    apply: ports.ApplyPort,
    spawn: ?ports.Spawn = null,
    notify: ?ports.Notify = null,
    /// Backlink groups whose lines are read (the rest show titles only).
    max_groups_with_lines: usize = 50,
};

pub const NotesSidebarModel = struct {
    o: Options,
    active: ?FileId = null,
    view: ?*IndexView = null,
    arena: std.heap.ArenaAllocator,
    dirty: std.atomic.Value(bool) = .init(true),

    backlinks: []const BacklinkGroup = &.{},
    outgoing: []const OutLink = &.{},
    props: []const PropRow = &.{},
    title: []const u8 = "",
    path: []const u8 = "",

    /// Unlinked mentions, shared with the worker computing them.
    shared: *Shared,

    // The tag tree, flattened for `TreeSource` (node = hash of the folded
    // tag, stable across rebuilds so open rows stay open).
    tag_nodes: []const *const TagNode = &.{},
    tag_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Bumped when the tag tree is rebuilt (the view reloads its tree).
    tags_version: u32 = 0,
    /// Bumped by every rebuild (views reset per-note state).
    version: u32 = 0,
    tag_kids: []const []const u32 = &.{},
    tag_roots: []const u32 = &.{},
    tag_filter: []const u8 = "",
    tag_filter_buf: [128]u8 = undefined,
    tag_sort: TagSort = .name,
    tags_arena: std.heap.ArenaAllocator,

    pub fn init(o: Options) !*NotesSidebarModel {
        const m = try o.gpa.create(NotesSidebarModel);
        errdefer o.gpa.destroy(m);
        const sh = try o.gpa.create(Shared);
        sh.* = .{ .gpa = o.gpa, .io = o.io, .arena = .init(o.gpa), .notify = o.notify };
        m.* = .{ .o = o, .arena = .init(o.gpa), .tags_arena = .init(o.gpa), .shared = sh };
        errdefer sh.release();
        try o.ix.subscribe(.{ .ctx = m, .on_event = onIndexEvent });
        return m;
    }

    pub fn deinit(m: *NotesSidebarModel) void {
        m.o.ix.unsubscribe(m);
        // A running job finds its generation stale and drops its result.
        m.cancelUnlinked();
        m.shared.mutex.lockUncancelable(m.o.io);
        m.shared.notify = null;
        m.shared.mutex.unlock(m.o.io);
        m.shared.release();
        if (m.view) |v| v.release();
        m.arena.deinit();
        m.tags_arena.deinit();
        m.o.gpa.destroy(m);
    }

    fn onIndexEvent(ctx: *anyopaque, ev: zg_notes.index.note_index.Event) void {
        _ = ev;
        const m: *NotesSidebarModel = @ptrCast(@alignCast(ctx));
        if (!m.dirty.swap(true, .acq_rel)) ports.Notify.call(m.o.notify);
    }

    /// Driven by the editor focus.
    pub fn setActiveNote(m: *NotesSidebarModel, id: ?FileId) void {
        if (m.active) |a| if (id) |b| if (a.eql(b)) return;
        if (m.active == null and id == null) return;
        m.active = id;
        m.cancelUnlinked();
        m.dirty.store(true, .release);
    }

    /// Rebuilds what changed; call on the UI thread before building.
    pub fn sync(m: *NotesSidebarModel) !void {
        if (!m.dirty.swap(false, .acq_rel)) return;
        try m.rebuild();
    }

    fn rebuild(m: *NotesSidebarModel) !void {
        const view = try m.o.ix.reader();
        if (m.view) |v| v.release();
        m.view = view;
        _ = m.arena.reset(.retain_capacity);
        m.version +%= 1;
        const a = m.arena.allocator();
        m.backlinks = &.{};
        m.outgoing = &.{};
        m.props = &.{};
        m.title = "";
        m.path = "";
        try m.rebuildTags(view);
        const id = m.active orelse return;
        const e = view.entry(id) orelse return;
        m.title = e.meta.title;
        m.path = e.path;
        m.backlinks = try backlinkGroups(a, view, m.o.content, id, m.o.max_groups_with_lines);
        m.outgoing = try outgoingLinks(a, view, m.o.vault, id);
        const text = (try m.o.content.read(m.o.content.ctx, a, id, e.path)) orelse "";
        m.props = try propRows(a, view, &e.meta, id, text);
    }

    // ---- unlinked mentions ----

    /// Starts computing unlinked mentions of the active note (the section
    /// was expanded). A note switch cancels it.
    pub fn requestUnlinked(m: *NotesSidebarModel) !void {
        try m.sync();
        const id = m.active orelse return;
        const view = m.view orelse return;
        m.cancelUnlinked();
        const sh = m.shared;
        const j = try m.o.gpa.create(Job);
        view.retain();
        _ = sh.refs.fetchAdd(1, .monotonic);
        sh.mutex.lockUncancelable(sh.io);
        sh.state = .running;
        j.* = .{ .sh = sh, .view = view, .content = m.o.content, .id = id, .gen = sh.gen };
        sh.mutex.unlock(sh.io);
        if (m.o.spawn) |s| s.run(s.ctx, Job.run, j) else Job.run(j);
    }

    fn cancelUnlinked(m: *NotesSidebarModel) void {
        const sh = m.shared;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        sh.gen += 1;
        _ = sh.arena.reset(.retain_capacity);
        sh.state = .idle;
    }

    /// The unlinked mentions state (valid until the next `setActiveNote`,
    /// `requestUnlinked` or edit).
    pub fn unlinkedState(m: *NotesSidebarModel) Unlinked {
        const sh = m.shared;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        return sh.state;
    }

    /// The unlinked-mentions slot, owned by the model and each running job.
    const Shared = struct {
        refs: std.atomic.Value(u32) = .init(1),
        gpa: Allocator,
        io: Io,
        mutex: Io.Mutex = .init,
        gen: u64 = 0,
        state: Unlinked = .idle,
        arena: std.heap.ArenaAllocator,
        notify: ?ports.Notify,

        fn release(sh: *Shared) void {
            if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
            sh.arena.deinit();
            sh.gpa.destroy(sh);
        }
    };

    /// One unlinked-mention computation; frees itself.
    const Job = struct {
        sh: *Shared,
        view: *IndexView,
        content: ContentSource,
        id: FileId,
        gen: u64,

        fn run(arg: *anyopaque) void {
            const j: *Job = @ptrCast(@alignCast(arg));
            const sh = j.sh;
            defer {
                j.view.release();
                sh.gpa.destroy(j);
                sh.release();
            }
            var arena: std.heap.ArenaAllocator = .init(sh.gpa);
            defer arena.deinit();
            const rows = unlinkedRows(arena.allocator(), j.view, j.content, j.id);
            sh.mutex.lockUncancelable(sh.io);
            if (sh.gen != j.gen) {
                sh.mutex.unlock(sh.io);
                return;
            }
            if (rows) |r| {
                sh.state = if (copyRows(sh.arena.allocator(), r)) |c| .{ .done = c } else |_| .{ .failed = "out of memory" };
            } else |e| sh.state = .{ .failed = @errorName(e) };
            const notify = sh.notify;
            sh.mutex.unlock(sh.io);
            ports.Notify.call(notify);
        }
    };

    // ---- edits ----

    /// Links one unlinked mention (`[[Title]]` or `[[Title|text]]`).
    pub fn linkMention(m: *NotesSidebarModel, row: UnlinkedRow) !u64 {
        return m.linkMentions(&.{row}, "Link mention");
    }

    /// Links every unlinked mention in one change.
    pub fn linkAll(m: *NotesSidebarModel) !?u64 {
        const st = m.unlinkedState();
        const rows = switch (st) {
            .done => |r| r,
            else => return null,
        };
        if (rows.len == 0) return null;
        return try m.linkMentions(rows, "Link all mentions");
    }

    fn linkMentions(m: *NotesSidebarModel, rows: []const UnlinkedRow, label: []const u8) !u64 {
        const view = m.view orelse return error.NoView;
        const id = m.active orelse return error.NoActiveNote;
        var arena: std.heap.ArenaAllocator = .init(m.o.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const target_path = view.pathOf(id) orelse return error.NoActiveNote;
        var changes: std.ArrayList(ports.FileChange) = .empty;
        // Rows are sorted by source then offset: one change per source.
        var i: usize = 0;
        while (i < rows.len) {
            var j = i + 1;
            while (j < rows.len and rows[j].mention.source.eql(rows[i].mention.source)) j += 1;
            const src = rows[i].mention.source;
            const path = view.pathOf(src) orelse return error.NoSuchNote;
            const base = (try m.o.content.read(m.o.content.ctx, a, src, path)) orelse return error.NoSuchNote;
            var names = view.names;
            var keys: zg_notes.index.names.KeyBuf = .{};
            const t = try zg_notes.refactor.link_text.shortestLinkText(a, &names, &keys, m.o.vault.id, path, id, target_path, false);
            var out: std.ArrayList(u8) = .empty;
            var at: usize = 0;
            for (rows[i..j]) |r| {
                const rg = r.mention.range;
                if (rg[0] < at or rg[1] > base.len) return error.StaleMention;
                const text = base[rg[0]..rg[1]];
                try out.appendSlice(a, base[at..rg[0]]);
                try out.appendSlice(a, "[[");
                try out.appendSlice(a, t);
                if (!std.mem.eql(u8, text, t)) {
                    try out.append(a, '|');
                    try out.appendSlice(a, text);
                }
                try out.appendSlice(a, "]]");
                at = rg[1];
            }
            try out.appendSlice(a, base[at..]);
            try changes.append(a, .{ .path = path, .base = base, .new = out.items });
            i = j;
        }
        const cs = try m.o.apply.apply(m.o.apply.ctx, label, changes.items);
        m.cancelUnlinked();
        return cs;
    }

    /// Sets property `name` of the active note (`null` value removes it).
    pub fn setProperty(m: *NotesSidebarModel, name: []const u8, value: ?Value) !u64 {
        const view = m.view orelse return error.NoView;
        const id = m.active orelse return error.NoActiveNote;
        var arena: std.heap.ArenaAllocator = .init(m.o.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = view.pathOf(id) orelse return error.NoActiveNote;
        const base = (try m.o.content.read(m.o.content.ctx, a, id, path)) orelse return error.NoSuchNote;
        const edit: zg_notes.fm_writer.PropEdit = if (value) |v| .{ .set = .{ .name = name, .value = v } } else .{ .remove = name };
        const new = try zg_notes.fm_writer.applyPropEdits(a, base, &.{edit});
        return m.o.apply.apply(m.o.apply.ctx, try std.fmt.allocPrint(a, "Set {s}", .{name}), &.{.{ .path = path, .base = base, .new = new }});
    }

    /// Creates the note for an unresolved outgoing link.
    pub fn createNote(m: *NotesSidebarModel, path: []const u8) !u64 {
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Create {s}", .{path}) catch "Create note";
        return m.o.apply.apply(m.o.apply.ctx, label, &.{.{ .path = path, .base = null, .new = "" }});
    }

    // ---- tags ----

    pub fn setTagFilter(m: *NotesSidebarModel, filter: []const u8) !void {
        const n = @min(filter.len, m.tag_filter_buf.len);
        @memcpy(m.tag_filter_buf[0..n], filter[0..n]);
        m.tag_filter = m.tag_filter_buf[0..n];
        if (m.view) |v| try m.rebuildTags(v);
    }

    pub fn setTagSort(m: *NotesSidebarModel, s: TagSort) !void {
        m.tag_sort = s;
        if (m.view) |v| try m.rebuildTags(v);
    }

    fn rebuildTags(m: *NotesSidebarModel, view: *const IndexView) !void {
        _ = m.tags_arena.reset(.retain_capacity);
        m.tag_index = .empty;
        m.tags_version +%= 1;
        const a = m.tags_arena.allocator();
        var nodes: std.ArrayList(*const TagNode) = .empty;
        var kids: std.ArrayList([]const u32) = .empty;
        const roots = try m.flattenTags(a, view.tagTree(), &nodes, &kids);
        m.tag_nodes = nodes.items;
        m.tag_kids = kids.items;
        m.tag_roots = roots;
        try m.tag_index.ensureTotalCapacity(a, @intCast(nodes.items.len));
        for (nodes.items, 0..) |n, i| m.tag_index.putAssumeCapacity(tagId(n), @intCast(i));
    }

    fn tagId(n: *const TagNode) u64 {
        return std.hash.Wyhash.hash(0, n.key);
    }

    /// The kept children of `n` (a node is kept when it or a descendant
    /// matches the filter), appended to `nodes` in display order.
    fn flattenTags(m: *NotesSidebarModel, a: Allocator, n: *const TagNode, nodes: *std.ArrayList(*const TagNode), kids: *std.ArrayList([]const u32)) ![]const u32 {
        const sorted = try a.dupe(*const TagNode, n.children);
        std.mem.sort(*const TagNode, sorted, m.tag_sort, struct {
            fn lt(s: TagSort, x: *const TagNode, y: *const TagNode) bool {
                if (s == .count and x.count != y.count) return x.count > y.count;
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.lt);
        var out: std.ArrayList(u32) = .empty;
        for (sorted) |c| {
            const idx: u32 = @intCast(nodes.items.len);
            try nodes.append(a, c);
            try kids.append(a, &.{});
            const sub = try m.flattenTags(a, c, nodes, kids);
            const keep = sub.len > 0 or m.tag_filter.len == 0 or std.ascii.indexOfIgnoreCase(c.full, m.tag_filter) != null;
            if (!keep) continue;
            kids.items[idx] = sub;
            try out.append(a, idx);
        }
        return out.items;
    }

    /// The tag tree for a `TreeView` (rows are `#tag (count)`).
    pub fn tagsSource(m: *NotesSidebarModel) TreeSource {
        return .{ .ptr = m, .vtable = &tag_vt };
    }

    /// The tag of a `tagsSource` node.
    pub fn tagOf(m: *const NotesSidebarModel, node: u64) ?*const TagNode {
        const i = m.tag_index.get(node) orelse return null;
        return m.tag_nodes[i];
    }

    const tag_vt: TreeSource.VTable = .{
        .root_count = tagRootCount,
        .child_count = tagChildCount,
        .child = tagChild,
        .label = tagLabel,
    };

    fn tagRootCount(p: *anyopaque) u32 {
        const m: *NotesSidebarModel = @ptrCast(@alignCast(p));
        return @intCast(m.tag_roots.len);
    }

    fn tagChildCount(p: *anyopaque, node: u64) ChildCount {
        const m: *NotesSidebarModel = @ptrCast(@alignCast(p));
        const i = m.tag_index.get(node) orelse return .leaf;
        const k = m.tag_kids[i];
        return if (k.len == 0) .leaf else .{ .known = @intCast(k.len) };
    }

    fn tagChild(p: *anyopaque, parent: ?u64, i: u32) u64 {
        const m: *NotesSidebarModel = @ptrCast(@alignCast(p));
        const idx = if (parent) |q| m.tag_kids[m.tag_index.get(q).?][i] else m.tag_roots[i];
        return tagId(m.tag_nodes[idx]);
    }

    fn tagLabel(p: *anyopaque, node: u64) []const u8 {
        const m: *NotesSidebarModel = @ptrCast(@alignCast(p));
        const n = m.tagOf(node) orelse return "";
        return std.fmt.allocPrint(m.tags_arena.allocator(), "#{s} ({d})", .{ n.name, n.count }) catch n.name;
    }
};

fn lessTitle(_: void, x: BacklinkGroup, y: BacklinkGroup) bool {
    return std.ascii.lessThanIgnoreCase(x.title, y.title);
}

/// Linked mentions of `id`, grouped by source note (by title), each row
/// the line holding the link.
pub fn backlinkGroups(a: Allocator, view: *const IndexView, content: ContentSource, id: FileId, max_with_lines: usize) ![]const BacklinkGroup {
    const refs = view.backlinks(id);
    var groups: std.ArrayList(BacklinkGroup) = .empty;
    var i: usize = 0;
    while (i < refs.len) {
        var j = i + 1;
        while (j < refs.len and refs[j].source.eql(refs[i].source)) j += 1;
        const src = refs[i].source;
        const e = view.entry(src) orelse {
            i = j;
            continue;
        };
        var rows: std.ArrayList(BacklinkRow) = .empty;
        if (groups.items.len < max_with_lines) if (try content.read(content.ctx, a, src, e.path)) |text| {
            for (refs[i..j]) |r| {
                const c = r.context;
                if (c[1] > text.len or c[0] > c[1]) continue;
                const l = e.meta.links[r.link_index];
                const hl: [2]u32 = .{ l.src[0] -| c[0], @min(l.src[1], c[1]) -| c[0] };
                try rows.append(a, .{ .text = text[c[0]..c[1]], .highlight = hl, .range = c });
            }
        };
        try groups.append(a, .{ .source = src, .title = e.meta.title, .path = e.path, .rows = rows.items });
        i = j;
    }
    std.mem.sort(BacklinkGroup, groups.items, {}, lessTitle);
    return groups.items;
}

pub fn outgoingLinks(a: Allocator, view: *const IndexView, vault: *const zg_notes.Vault, id: FileId) ![]const OutLink {
    const meta = view.note(id) orelse return &.{};
    const from = view.pathOf(id) orelse return &.{};
    var out: std.ArrayList(OutLink) = .empty;
    var cands: std.ArrayList(FileId) = .empty;
    for (meta.links) |l| {
        cands.clearRetainingCapacity();
        const r = try view.resolve(a, id, l.target, l.kind, &cands);
        var o: OutLink = .{ .target = if (l.target.len == 0) "(this note)" else l.target, .kind = switch (r.kind) {
            .note => .note,
            .attachment => .attachment,
            .self => .self,
            .unresolved => .unresolved,
        } };
        if (r.kind == .note or r.kind == .attachment) o.path = view.pathOf(r.id);
        if (r.ambiguous) {
            o.kind = .ambiguous;
            var cs: std.ArrayList([]const u8) = .empty;
            for (cands.items) |c| if (view.pathOf(c)) |p| try cs.append(a, p);
            o.candidates = cs.items;
        }
        if (r.kind == .unresolved) o.create_path = try zg_notes.lang.link_nav.newNotePath(a, &vault.config, from, l.target, l.kind);
        try out.append(a, o);
    }
    return out.items;
}

pub fn propRows(a: Allocator, view: *const IndexView, meta: *const zg_notes.NoteMeta, id: FileId, text: []const u8) ![]const PropRow {
    var out: std.ArrayList(PropRow) = .empty;
    for (meta.props) |p| {
        const info = for (view.properties()) |*pi| {
            if (std.ascii.eqlIgnoreCase(pi.name, p.name)) break pi;
        } else null;
        const conflict = if (info) |pi| for (pi.conflicts) |c| {
            if (c.eql(id)) break true;
        } else false else false;
        const s = p.node.src;
        try out.append(a, .{
            .name = p.name,
            .ty = view.propertyType(p.name),
            .value = p.node.value,
            .raw = if (s[1] <= text.len and s[0] <= s[1]) text[s[0]..s[1]] else "",
            .conflict = conflict,
        });
    }
    return out.items;
}

fn unlinkedRows(a: Allocator, view: *const IndexView, content: ContentSource, id: FileId) ![]const UnlinkedRow {
    var ms: std.ArrayList(Mention) = .empty;
    try zg_notes.index.mentions.unlinkedMentions(view, a, content, id, &ms);
    var out: std.ArrayList(UnlinkedRow) = .empty;
    var cur_src: ?FileId = null;
    var text: []const u8 = "";
    for (ms.items) |mn| {
        const e = view.entry(mn.source) orelse continue;
        if (cur_src == null or !cur_src.?.eql(mn.source)) {
            text = (try content.read(content.ctx, a, mn.source, e.path)) orelse "";
            cur_src = mn.source;
        }
        if (mn.range[1] > text.len) continue;
        const ls = if (std.mem.lastIndexOfScalar(u8, text[0..mn.range[0]], '\n')) |k| k + 1 else 0;
        const le = std.mem.indexOfScalarPos(u8, text, mn.range[1], '\n') orelse text.len;
        try out.append(a, .{
            .mention = mn,
            .source_title = e.meta.title,
            .source_path = e.path,
            .text = text[ls..le],
            .highlight = .{ @intCast(mn.range[0] - ls), @intCast(mn.range[1] - ls) },
        });
    }
    return out.items;
}

fn copyRows(a: Allocator, rows: []const UnlinkedRow) ![]const UnlinkedRow {
    const out = try a.alloc(UnlinkedRow, rows.len);
    for (rows, out) |r, *o| {
        o.* = r;
        o.mention.term = try a.dupe(u8, r.mention.term);
        o.source_title = try a.dupe(u8, r.source_title);
        o.source_path = try a.dupe(u8, r.source_path);
        o.text = try a.dupe(u8, r.text);
    }
    return out;
}
